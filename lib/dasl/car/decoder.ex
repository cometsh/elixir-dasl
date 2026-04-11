defmodule DASL.CAR.Decoder do
  @moduledoc """
  Decoder for DASL CAR binary streams.
  Spec: https://dasl.ing/car.html
  """

  alias DASL.{CAR, CID, DRISL}
  alias Varint.LEB128

  @cid_byte_size 36

  @type header_error() :: {:error, :header, atom()}
  @type block_error() :: {:error, :block, atom()}

  @doc """
  Decodes a CAR binary stream into a `DASL.CAR` struct.

  Accepts the same options as `DASL.CAR.decode/2`.
  """
  @spec decode(binary(), keyword()) :: {:ok, CAR.t()} | header_error() | block_error()
  def decode(binary, opts \\ []) do
    verify = Keyword.get(opts, :verify, true)

    with {:ok, metadata, rest} <- header(binary),
         {:ok, blocks} <- blocks(rest, %{}, verify) do
      roots = Map.fetch!(metadata, "roots")
      {:ok, %CAR{version: 1, roots: roots, blocks: blocks}}
    end
  end

  @spec header(binary()) :: {:ok, map(), binary()} | header_error()
  defp header(binary) do
    with {length, rest} <- LEB128.decode(binary),
         :ok <- validate_header_length(length),
         <<header_bin::binary-size(length), rest::binary>> <- rest,
         {:ok, metadata, <<>>} <- DRISL.decode(header_bin),
         :ok <- validate_header_map(metadata) do
      {:ok, metadata, rest}
    else
      <<_::binary>> -> {:error, :header, :too_short}
      {:ok, _, leftover} when is_binary(leftover) -> {:error, :header, :invalid_encoding}
      {:error, :header, _} = err -> err
      {:error, _reason} -> {:error, :header, :invalid_encoding}
    end
  end

  @spec validate_header_length(non_neg_integer()) :: :ok | header_error()
  defp validate_header_length(0), do: {:error, :header, :empty}
  defp validate_header_length(_), do: :ok

  @spec validate_header_map(any()) :: :ok | header_error()
  defp validate_header_map(metadata) when not is_map(metadata),
    do: {:error, :header, :not_a_map}

  defp validate_header_map(%{"version" => version}) when version != 1,
    do: {:error, :header, :unsupported_version}

  defp validate_header_map(%{"version" => 1, "roots" => roots}) when is_list(roots) do
    if Enum.all?(roots, &match?(%CID{}, &1)) do
      :ok
    else
      {:error, :header, :invalid_roots}
    end
  end

  defp validate_header_map(%{"version" => 1}), do: {:error, :header, :missing_roots}
  defp validate_header_map(_), do: {:error, :header, :missing_version}

  @spec blocks(binary(), map(), boolean()) :: {:ok, map()} | block_error()
  defp blocks(<<>>, acc, _verify), do: {:ok, acc}

  defp blocks(binary, acc, verify) do
    with {length, rest} <- LEB128.decode(binary),
         :ok <- validate_block_length(length),
         <<cid_bytes::binary-size(@cid_byte_size), data::binary-size(length - @cid_byte_size),
           rest::binary>> <- rest,
         {:ok, cid} <- parse_cid(cid_bytes),
         :ok <- maybe_verify(verify, cid, data) do
      blocks(rest, Map.put(acc, cid, data), verify)
    else
      <<_::binary>> -> {:error, :block, :too_short}
      {:error, :block, _} = err -> err
      {:error, reason} -> {:error, :block, reason}
    end
  end

  @spec validate_block_length(non_neg_integer()) :: :ok | block_error()
  defp validate_block_length(length) when length < @cid_byte_size,
    do: {:error, :block, :too_short}

  defp validate_block_length(_), do: :ok

  @spec parse_cid(binary()) :: {:ok, CID.t()} | block_error()
  defp parse_cid(cid_bytes) do
    case CID.from_bytes(cid_bytes) do
      {:ok, cid} -> {:ok, cid}
      {:error, reason} -> {:error, :block, {:invalid_cid, reason}}
    end
  end

  @spec maybe_verify(boolean(), CID.t(), binary()) :: :ok | block_error()
  defp maybe_verify(false, _cid, _data), do: :ok

  defp maybe_verify(true, cid, data) do
    if CID.verify?(cid, data) do
      :ok
    else
      {:error, :block, :cid_mismatch}
    end
  end
end
