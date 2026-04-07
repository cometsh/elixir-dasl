defmodule DASL.CAR.DRISL do
  @moduledoc """
  A DRISL-aware CAR variant.

  Wraps `DASL.CAR` with transparent DRISL encoding and decoding of block data.
  Blocks are stored as decoded Elixir terms keyed by their `DASL.CID`. CIDs are
  computed over the DRISL-encoded form of each term using the `:drisl` codec.

  For a lower-level CAR that stores raw binaries, see `DASL.CAR`.
  """

  use TypedStruct
  alias DASL.{CAR, CID, DRISL}
  alias DASL.CAR.StreamDecoder

  typedstruct enforce: true do
    field :version, pos_integer(), default: 1
    field :roots, list(CID.t()), default: []
    field :blocks, %{CID.t() => any()}, default: %{}
  end

  @doc """
  Decodes a CAR binary stream into a `DASL.CAR.DRISL` struct.

  Each block's raw binary is decoded as a DRISL term after CID verification.

  ## Options

    * `:verify` — boolean, default `true`. Verifies each block's raw data
      against its CID before DRISL decoding. Returns
      `{:error, :block, :cid_mismatch}` on failure.

  """
  @spec decode(binary(), keyword()) ::
          {:ok, t()} | CAR.Decoder.header_error() | CAR.Decoder.block_error()
  def decode(binary, opts \\ []) do
    with {:ok, raw_car} <- CAR.decode(binary, opts),
         {:ok, decoded_blocks} <- decode_blocks(raw_car.blocks) do
      {:ok,
       %__MODULE__{
         version: raw_car.version,
         roots: raw_car.roots,
         blocks: decoded_blocks
       }}
    end
  end

  @doc """
  Encodes a `DASL.CAR.DRISL` struct into a CAR binary stream.

  Each block's term value is DRISL-encoded before writing.

  ## Options

    * `:verify` — boolean, default `true`. Verifies each DRISL-encoded block
      binary against its CID before writing. Returns
      `{:error, :block, :cid_mismatch}` on failure.

  """
  @spec encode(t(), keyword()) ::
          {:ok, binary()} | CAR.Encoder.header_error() | CAR.Encoder.block_error()
  def encode(%__MODULE__{version: 1, roots: roots, blocks: blocks}, opts \\ []) do
    with {:ok, encoded_blocks} <- encode_blocks(blocks) do
      raw_car = %CAR{version: 1, roots: roots, blocks: encoded_blocks}
      CAR.encode(raw_car, opts)
    end
  end

  @doc """
  Transforms a stream of binary chunks into a stream of decoded CAR items,
  with block data DRISL-decoded into Elixir terms.

  Each element of `chunk_stream` must be a binary of any size. Items are
  emitted as soon as a complete frame has been buffered:

    * `{:header, version, roots}` — emitted once when the header is parsed
    * `{:block, cid, term}` — emitted per block; `term` is the DRISL-decoded
      Elixir value

  Raises on parse errors (invalid header, truncated stream, CID mismatch,
  or DRISL decoding failure).

  ## Options

    * `:verify` — boolean, default `true`. Verifies each block against its CID
      before DRISL decoding.

  ## Examples

      File.stream!("large.car", [], 65_536)
      |> DASL.CAR.DRISL.stream_decode()
      |> Enum.each(fn
        {:header, _version, roots} -> IO.inspect(roots)
        {:block, cid, term}        -> IO.inspect({cid, term})
      end)

  """
  @spec stream_decode(Enumerable.t(), keyword()) :: Enumerable.t()
  def stream_decode(chunk_stream, opts \\ []) do
    chunk_stream
    |> StreamDecoder.decode_stream(opts)
    |> Stream.map(fn
      {:header, version, roots} ->
        {:header, version, roots}

      {:block, cid, raw} ->
        case DRISL.decode(raw) do
          {:ok, term, ""} ->
            {:block, cid, term}

          {:ok, _, _leftover} ->
            raise "CAR.DRISL stream: trailing bytes in block #{inspect(cid)}"

          {:error, reason} ->
            raise "CAR.DRISL stream: failed to DRISL-decode block #{inspect(cid)}: #{inspect(reason)}"
        end
    end)
  end

  @doc """
  DRISL-encodes `term`, computes its CID using the `:drisl` codec, adds the CID
  to the blocks (storing the original term, not the encoded binary), and returns
  the updated struct alongside the computed CID.

  Returns `{:error, reason}` if DRISL encoding fails.
  """
  @spec add_block(t(), any()) :: {:ok, {t(), CID.t()}} | {:error, atom()}
  def add_block(%__MODULE__{blocks: blocks} = car, term) do
    with {:ok, encoded} <- DRISL.encode(term) do
      cid = CID.compute(encoded, :drisl)
      {:ok, {%__MODULE__{car | blocks: Map.put(blocks, cid, term)}, cid}}
    end
  end

  @doc """
  Adds a CID to the CAR's roots after verifying it exists in the blocks.

  Returns `{:ok, updated_car}` on success, `{:ok, car}` unchanged if the CID
  is already a root (no-op), or `{:error, :not_in_blocks}` if the CID is not
  present in the blocks.
  """
  @spec add_root(t(), CID.t()) :: {:ok, t()} | {:error, :not_in_blocks}
  def add_root(%__MODULE__{roots: roots, blocks: blocks} = car, %CID{} = cid) do
    cond do
      cid in roots -> {:ok, car}
      not Map.has_key?(blocks, cid) -> {:error, :not_in_blocks}
      true -> {:ok, %__MODULE__{car | roots: roots ++ [cid]}}
    end
  end

  @doc """
  Removes a CID from the CAR's roots. No-op if the CID is not a root.
  """
  @spec remove_root(t(), CID.t()) :: t()
  def remove_root(%__MODULE__{roots: roots} = car, %CID{} = cid),
    do: %__MODULE__{car | roots: List.delete(roots, cid)}

  @doc """
  Removes a CID from the CAR's blocks.

  Returns `{:ok, updated_car}` on success (including when the CID is absent —
  no-op), or `{:error, :is_a_root}` if the CID is currently listed as a root.
  Call `remove_root/2` first.
  """
  @spec remove_block(t(), CID.t()) :: {:ok, t()} | {:error, :is_a_root}
  def remove_block(%__MODULE__{roots: roots, blocks: blocks} = car, %CID{} = cid) do
    if cid in roots do
      {:error, :is_a_root}
    else
      {:ok, %__MODULE__{car | blocks: Map.delete(blocks, cid)}}
    end
  end

  @spec decode_blocks(%{CID.t() => binary()}) ::
          {:ok, %{CID.t() => any()}} | CAR.Decoder.block_error()
  defp decode_blocks(blocks) do
    Enum.reduce_while(blocks, {:ok, %{}}, fn {cid, bin}, {:ok, acc} ->
      case DRISL.decode(bin) do
        {:ok, term, ""} -> {:cont, {:ok, Map.put(acc, cid, term)}}
        {:ok, _, _} -> {:halt, {:error, :block, :trailing_bytes}}
        {:error, reason} -> {:halt, {:error, :block, reason}}
      end
    end)
  end

  @spec encode_blocks(%{CID.t() => any()}) ::
          {:ok, %{CID.t() => binary()}} | CAR.Encoder.block_error()
  defp encode_blocks(blocks) do
    Enum.reduce_while(blocks, {:ok, %{}}, fn {cid, term}, {:ok, acc} ->
      case DRISL.encode(term) do
        {:ok, bin} -> {:cont, {:ok, Map.put(acc, cid, bin)}}
        {:error, reason} -> {:halt, {:error, :block, reason}}
      end
    end)
  end
end
