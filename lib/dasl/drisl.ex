defmodule DASL.DRISL do
  @moduledoc """
  DRISL (Deterministic Representation for Interoperable Structures & Links).

  A deterministic CBOR profile with native support for CIDs as links. Delegates
  to `DASL.DRISL.Decoder` and `DASL.DRISL.Encoder` for the actual work.

  Spec: https://dasl.ing/drisl.html
  """

  @doc """
  Decodes a DRISL-encoded binary into an Elixir term.

  CIDs encoded as CBOR tag 42 are decoded into `%DASL.CID{}` structs.
  Returns `{:ok, term, rest}` on success, or `{:error, reason}` on failure.

  ## Examples

      iex> DASL.DRISL.decode(<<0xa1, 0x61, 0x61, 0x01>>)
      {:ok, %{"a" => 1}, ""}

      iex> DASL.DRISL.decode(<<0x83, 0x01, 0x02, 0x03>>)
      {:ok, [1, 2, 3], ""}

  """
  @spec decode(binary()) :: {:ok, any(), binary()} | {:error, atom()}
  defdelegate decode(binary), to: DASL.DRISL.Decoder

  @doc """
  Encodes an Elixir term into a DRISL-compliant CBOR binary.

  Map keys are sorted in bytewise-lexicographic order of their encoded form.
  `%DASL.CID{}` values are encoded as CBOR tag 42 bytestrings.
  Returns `{:ok, binary}` on success, or `{:error, reason}` on failure.

  ## Examples

      iex> DASL.DRISL.encode(%{"a" => 1})
      {:ok, <<0xa1, 0x61, 0x61, 0x01>>}

      iex> DASL.DRISL.encode([1, 2, 3])
      {:ok, <<0x83, 0x01, 0x02, 0x03>>}

      iex> DASL.DRISL.encode(true)
      {:ok, <<0xf5>>}

  """
  @spec encode(any()) :: {:ok, binary()} | {:error, atom()}
  defdelegate encode(term), to: DASL.DRISL.Encoder
end
