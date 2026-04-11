defmodule DASL.CAR.Encoder do
  @moduledoc """
  Encoder for DASL CAR binary streams.
  Spec: https://dasl.ing/car.html
  """

  alias DASL.{CAR, CID, DRISL}
  alias Varint.LEB128

  @type header_error() :: {:error, :header, atom()}
  @type block_error() :: {:error, :block, atom()}

  @doc """
  Encodes a `DASL.CAR` struct into a CAR binary stream.

  Accepts the same options as `DASL.CAR.encode/2`.
  """
  @spec encode(CAR.t(), keyword()) :: {:ok, binary()} | header_error() | block_error()
  def encode(%CAR{version: 1, roots: roots, blocks: blocks}, opts \\ []) do
    verify = Keyword.get(opts, :verify, true)

    with {:ok, header_iodata} <- encode_header(roots),
         {:ok, blocks_iodata} <- encode_blocks(blocks, verify) do
      {:ok, IO.iodata_to_binary([header_iodata, blocks_iodata])}
    end
  end

  @spec encode_header(list(CID.t())) :: {:ok, iodata()} | header_error()
  defp encode_header(roots) do
    with :ok <- validate_roots(roots),
         {:ok, metadata_bin} <- DRISL.encode(%{"version" => 1, "roots" => roots}) do
      {:ok, [LEB128.encode(byte_size(metadata_bin)), metadata_bin]}
    else
      {:error, :header, _} = err -> err
      {:error, reason} -> {:error, :header, reason}
    end
  end

  @spec validate_roots(any()) :: :ok | header_error()
  defp validate_roots(roots) when not is_list(roots), do: {:error, :header, :invalid_roots}

  defp validate_roots(roots) do
    if Enum.all?(roots, &match?(%CID{}, &1)) do
      :ok
    else
      {:error, :header, :invalid_roots}
    end
  end

  @spec encode_blocks(map(), boolean()) :: {:ok, iodata()} | block_error()
  defp encode_blocks(blocks, verify) do
    Enum.reduce_while(blocks, {:ok, []}, fn {cid, data}, {:ok, acc} ->
      case encode_block(cid, data, verify) do
        {:ok, block_iodata} -> {:cont, {:ok, [acc | [block_iodata]]}}
        {:error, _, _} = err -> {:halt, err}
      end
    end)
  end

  @spec encode_block(CID.t(), binary(), boolean()) :: {:ok, iodata()} | block_error()
  defp encode_block(%CID{bytes: cid_bytes} = cid, data, verify) when is_binary(data) do
    with :ok <- maybe_verify(verify, cid, data) do
      {:ok, [LEB128.encode(byte_size(cid_bytes) + byte_size(data)), cid_bytes, data]}
    end
  end

  defp encode_block(_cid, _data, _verify), do: {:error, :block, :data_must_be_binary}

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
