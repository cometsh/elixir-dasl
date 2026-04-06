defmodule DASL.CAR do
  @moduledoc """
  Struct and entry points for DASL CAR files.

  Blocks are stored as raw binaries keyed by their `DASL.CID`. For a
  higher-level variant that transparently encodes/decodes block data as DRISL,
  see `DASL.CAR.DRISL`.

  Spec: https://dasl.ing/car.html
  """

  use TypedStruct
  alias DASL.{CAR, CID}

  typedstruct enforce: true do
    field :version, pos_integer(), default: 1
    field :roots, list(CID.t()), default: []
    field :blocks, %{CID.t() => binary()}, default: %{}
  end

  @doc """
  Decodes a CAR binary stream into a `DASL.CAR` struct.

  ## Options

    * `:verify` — boolean, default `true`. When enabled, each block's raw data
      is verified against its CID digest using `DASL.CID.verify?/2`. Returns
      `{:error, :block, :cid_mismatch}` on failure.

  """
  @spec decode(binary(), keyword()) ::
          {:ok, t()} | CAR.Decoder.header_error() | CAR.Decoder.block_error()
  def decode(binary, opts \\ []), do: CAR.Decoder.decode(binary, opts)

  @doc """
  Encodes a `DASL.CAR` struct into a CAR binary stream.

  ## Options

    * `:verify` — boolean, default `true`. When enabled, the block binary is
      verified against its CID digest using `DASL.CID.verify?/2`. Returns
      `{:error, :block, :cid_mismatch}` on failure.

  """
  @spec encode(t(), keyword()) ::
          {:ok, binary()} | CAR.Encoder.header_error() | CAR.Encoder.block_error()
  def encode(%CAR{} = car, opts \\ []), do: CAR.Encoder.encode(car, opts)

  @doc """
  Computes the CID for `data`, adds it to the CAR's blocks, and returns the
  updated struct alongside the computed CID.

  The CID is computed using the `:raw` codec.
  """
  @spec add_block(t(), binary()) :: {t(), CID.t()}
  def add_block(%CAR{blocks: blocks} = car, data) when is_binary(data) do
    cid = CID.compute(data, :raw)
    {%CAR{car | blocks: Map.put(blocks, cid, data)}, cid}
  end

  @doc """
  Adds a CID to the CAR's roots after verifying it exists in the blocks.

  Returns `{:ok, updated_car}` on success, `{:ok, car}` unchanged if the CID
  is already a root (no-op), or `{:error, :not_in_blocks}` if the CID is not
  present in the blocks.
  """
  @spec add_root(t(), CID.t()) :: {:ok, t()} | {:error, :not_in_blocks}
  def add_root(%CAR{roots: roots, blocks: blocks} = car, %CID{} = cid) do
    cond do
      cid in roots -> {:ok, car}
      not Map.has_key?(blocks, cid) -> {:error, :not_in_blocks}
      true -> {:ok, %CAR{car | roots: roots ++ [cid]}}
    end
  end

  @doc """
  Removes a CID from the CAR's roots. No-op if the CID is not a root.
  """
  @spec remove_root(t(), CID.t()) :: t()
  def remove_root(%CAR{roots: roots} = car, %CID{} = cid),
    do: %CAR{car | roots: List.delete(roots, cid)}

  @doc """
  Removes a CID from the CAR's blocks.

  Returns `{:ok, updated_car}` on success (including when the CID is absent —
  no-op), or `{:error, :is_a_root}` if the CID is currently listed as a root.
  Call `remove_root/2` first to remove it from roots before removing the block.
  """
  @spec remove_block(t(), CID.t()) :: {:ok, t()} | {:error, :is_a_root}
  def remove_block(%CAR{roots: roots, blocks: blocks} = car, %CID{} = cid) do
    if cid in roots do
      {:error, :is_a_root}
    else
      {:ok, %CAR{car | blocks: Map.delete(blocks, cid)}}
    end
  end
end
