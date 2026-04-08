defmodule DASL.CID do
  @moduledoc """
  DASL content identifier (CID).

  A CID is a self-describing content address: it encodes a version, a codec
  (`:raw` or `:drisl`), and a SHA-256 digest. CIDs can be round-tripped
  through their canonical multibase string form, constructed by hashing
  arbitrary data with `compute/2`, and verified against their content with
  `verify?/2`.

  Spec: https://dasl.ing/cid.html
  """

  use TypedStruct

  @codec_raw 0x55
  @codec_drisl 0x71
  @hash_sha256 0x12
  @hash_size 32

  @type codec :: :raw | :drisl

  typedstruct enforce: true do
    field :version, pos_integer()
    field :codec, codec()
    field :hash_type, non_neg_integer()
    field :hash_size, pos_integer()
    field :digest, binary()
    field :bytes, binary()
  end

  @doc """
  Parses a string-encoded CID into raw bytes.

  ## Examples

      iex> DASL.CID.parse("bafkreifzjut3te2nhyekklss27nh3k72ysco7y32koao5eei66wof36n5e")
      {:ok, <<1, 85, 18, 32, 185, 77, 39, 185, 147, 77, 62, 8, 165, 46, 82, 215, 218,
              125, 171, 250, 196, 132, 239, 227, 122, 83, 128, 238, 144, 136, 247, 172,
              226, 239, 205, 233>>}

      iex> DASL.CID.parse("zQmInvalidPrefix")
      {:error, "CID must start with 'b'"}

      iex> DASL.CID.parse("b!!!!notbase32")
      {:error, "invalid base32 encoding"}

  """
  @spec parse(String.t()) :: {:ok, binary()} | {:error, String.t()}
  def parse(<<"b", rest::binary>>) do
    case Base.decode32(rest, case: :lower, padding: false) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, "invalid base32 encoding"}
    end
  end

  def parse(_), do: {:error, "CID must start with 'b'"}

  @doc """
  Decodes a raw CID bytestring into its constituent fields.

  Returns `{:ok, map}` on success, or `{:error, message}` if the bytes do not
  conform to the CID spec (unsupported version, unknown codec, wrong hash
  algorithm or size, truncated input).

  ## Examples

      iex> bytes = <<1, 85, 18, 32, 185, 77, 39, 185, 147, 77, 62, 8, 165, 46, 82, 215,
      ...>           218, 125, 171, 250, 196, 132, 239, 227, 122, 83, 128, 238, 144, 136,
      ...>           247, 172, 226, 239, 205, 233>>
      iex> DASL.CID.decode(bytes)
      {:ok, %{version: 1, codec: :raw, hash_type: 18, hash_size: 32,
              digest: <<185, 77, 39, 185, 147, 77, 62, 8, 165, 46, 82, 215, 218, 125,
                        171, 250, 196, 132, 239, 227, 122, 83, 128, 238, 144, 136, 247,
                        172, 226, 239, 205, 233>>}}

      iex> DASL.CID.decode(<<2, 85, 18, 32>> <> :binary.copy(<<0>>, 32))
      {:error, "unsupported CID version: 2"}

      iex> DASL.CID.decode(<<1, 0xAB, 18, 32>> <> :binary.copy(<<0>>, 32))
      {:error, "unsupported codec: 0xAB"}

      iex> DASL.CID.decode(<<1, 85, 0x11, 32>> <> :binary.copy(<<0>>, 32))
      {:error, "unsupported hash type: 0x11"}

      iex> DASL.CID.decode(<<1, 85, 18, 31>> <> :binary.copy(<<0>>, 32))
      {:error, "invalid hash size: 31"}

  """
  @spec decode(binary()) :: {:ok, map()} | {:error, String.t()}
  def decode(<<1, codec_byte, @hash_sha256, hash_size, digest::binary>>)
      when hash_size == @hash_size and byte_size(digest) == @hash_size do
    with {:ok, codec} <- decode_codec(codec_byte) do
      {:ok,
       %{
         version: 1,
         codec: codec,
         hash_type: @hash_sha256,
         hash_size: @hash_size,
         digest: digest
       }}
    end
  end

  def decode(<<version, _rest::binary>>) when version != 1,
    do: {:error, "unsupported CID version: #{version}"}

  def decode(<<1, codec_byte, _rest::binary>>) when codec_byte not in [@codec_raw, @codec_drisl],
    do: {:error, "unsupported codec: 0x#{Integer.to_string(codec_byte, 16)}"}

  def decode(<<1, _codec, hash_type, _rest::binary>>) when hash_type != @hash_sha256,
    do: {:error, "unsupported hash type: 0x#{Integer.to_string(hash_type, 16)}"}

  def decode(<<1, _codec, @hash_sha256, hash_size, _rest::binary>>)
      when hash_size != @hash_size,
      do: {:error, "invalid hash size: #{hash_size}"}

  def decode(_), do: {:error, "malformed CID bytes"}

  @doc """
  Constructs a `DASL.CID` from a string-encoded CID.

  ## Examples

      iex> {:ok, cid} = DASL.CID.new("bafkreifzjut3te2nhyekklss27nh3k72ysco7y32koao5eei66wof36n5e")
      iex> cid.version
      1
      iex> cid.codec
      :raw
      iex> cid.hash_type
      18
      iex> cid.hash_size
      32

      iex> DASL.CID.new("not-a-cid")
      {:error, "CID must start with 'b'"}

  """
  @spec new(String.t()) :: {:ok, t()} | {:error, String.t()}
  def new(cid_string) when is_binary(cid_string) do
    with {:ok, bytes} <- parse(cid_string),
         {:ok, fields} <- decode(bytes) do
      {:ok,
       struct!(__MODULE__,
         version: fields.version,
         codec: fields.codec,
         hash_type: fields.hash_type,
         hash_size: fields.hash_size,
         digest: fields.digest,
         bytes: bytes
       )}
    end
  end

  @doc """
  Encodes a `DASL.CID` back to its canonical string form.

  ## Examples

      iex> {:ok, cid} = DASL.CID.new("bafkreifzjut3te2nhyekklss27nh3k72ysco7y32koao5eei66wof36n5e")
      iex> DASL.CID.encode(cid)
      "bafkreifzjut3te2nhyekklss27nh3k72ysco7y32koao5eei66wof36n5e"

  """
  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{bytes: bytes}),
    do: "b" <> Base.encode32(bytes, case: :lower, padding: false)

  @doc """
  Constructs a `DASL.CID` from a CBOR tag 42 value.

  ## Examples

      iex> {:ok, cid} = DASL.CID.new("bafkreifzjut3te2nhyekklss27nh3k72ysco7y32koao5eei66wof36n5e")
      iex> tag = DASL.CID.to_cbor(cid)
      iex> {:ok, decoded} = DASL.CID.from_cbor(tag)
      iex> decoded.codec
      :raw

      iex> DASL.CID.from_cbor(%CBOR.Tag{tag: 1, value: "not a cid"})
      {:error, "invalid CBOR CID tag"}

  """
  @spec from_cbor(CBOR.Tag.t()) :: {:ok, t()} | {:error, String.t()}
  def from_cbor(%CBOR.Tag{
        tag: 42,
        value: %CBOR.Tag{tag: :bytes, value: <<0, cid_bytes::binary>>}
      }) do
    with {:ok, fields} <- decode(cid_bytes) do
      {:ok,
       struct!(__MODULE__,
         version: fields.version,
         codec: fields.codec,
         hash_type: fields.hash_type,
         hash_size: fields.hash_size,
         digest: fields.digest,
         bytes: cid_bytes
       )}
    end
  end

  def from_cbor(_), do: {:error, "invalid CBOR CID tag"}

  @doc """
  Converts a `DASL.CID` to a CBOR tag 42 value.

  ## Examples

      iex> {:ok, cid} = DASL.CID.new("bafkreifzjut3te2nhyekklss27nh3k72ysco7y32koao5eei66wof36n5e")
      iex> DASL.CID.to_cbor(cid)
      %CBOR.Tag{
        tag: 42,
        value: %CBOR.Tag{
          tag: :bytes,
          value: <<0, 1, 85, 18, 32, 185, 77, 39, 185, 147, 77, 62, 8, 165, 46, 82,
                   215, 218, 125, 171, 250, 196, 132, 239, 227, 122, 83, 128, 238,
                   144, 136, 247, 172, 226, 239, 205, 233>>
        }
      }

  """
  @spec to_cbor(t()) :: CBOR.Tag.t()
  def to_cbor(%__MODULE__{bytes: bytes}),
    do: %CBOR.Tag{tag: 42, value: %CBOR.Tag{tag: :bytes, value: <<0, bytes::binary>>}}

  @doc """
  Computes a CID for an arbitrary binary, defaulting to the `:raw` codec.

  ## Examples

      iex> cid = DASL.CID.compute("hello world")
      iex> cid.codec
      :raw
      iex> cid.version
      1
      iex> cid.hash_size
      32

      iex> cid = DASL.CID.compute("hello world", :drisl)
      iex> cid.codec
      :drisl

  """
  @spec compute(binary(), codec()) :: t()
  def compute(data, codec \\ :raw) when is_binary(data) and codec in [:raw, :drisl] do
    digest = :crypto.hash(:sha256, data)
    codec_byte = codec_to_byte(codec)
    bytes = <<1, codec_byte, @hash_sha256, @hash_size>> <> digest

    struct!(__MODULE__,
      version: 1,
      codec: codec,
      hash_type: @hash_sha256,
      hash_size: @hash_size,
      digest: digest,
      bytes: bytes
    )
  end

  @doc """
  Returns `true` if `data` hashes to the digest recorded in `cid`, `false` otherwise.

  Uses a constant-time comparison to avoid timing attacks.

  ## Examples

      iex> cid = DASL.CID.compute("hello world")
      iex> DASL.CID.verify?(cid, "hello world")
      true

      iex> cid = DASL.CID.compute("hello world")
      iex> DASL.CID.verify?(cid, "goodbye world")
      false

  """
  @spec verify?(t(), binary()) :: boolean()
  def verify?(%__MODULE__{digest: digest}, data) when is_binary(data) do
    candidate = :crypto.hash(:sha256, data)
    :crypto.hash_equals(digest, candidate)
  end

  defp decode_codec(@codec_raw), do: {:ok, :raw}
  defp decode_codec(@codec_drisl), do: {:ok, :drisl}

  defp decode_codec(byte),
    do: {:error, "unsupported codec: 0x#{Integer.to_string(byte, 16)}"}

  defp codec_to_byte(:raw), do: @codec_raw
  defp codec_to_byte(:drisl), do: @codec_drisl
end

defimpl String.Chars, for: DASL.CID do
  def to_string(value), do: DASL.CID.encode(value)
end

defimpl Inspect, for: DASL.CID do
  def inspect(cid, _opts) do
    cid = DASL.CID.encode(cid)
    ~s'DASL.CID.new("#{cid}")'
  end
end
