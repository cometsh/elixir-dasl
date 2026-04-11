defmodule DASL.CIDTest do
  use ExUnit.Case, async: true
  doctest DASL.CID

  # SHA-256("hello world")
  @digest <<185, 77, 39, 185, 147, 77, 62, 8, 165, 46, 82, 215, 218, 125, 171, 250, 196, 132, 239,
            227, 122, 83, 128, 238, 144, 136, 247, 172, 226, 239, 205, 233>>

  @raw_bytes <<1, 0x55, 0x12, 0x20>> <> @digest
  @drisl_bytes <<1, 0x71, 0x12, 0x20>> <> @digest

  @raw_cid "bafkreifzjut3te2nhyekklss27nh3k72ysco7y32koao5eei66wof36n5e"
  @drisl_cid "bafyreifzjut3te2nhyekklss27nh3k72ysco7y32koao5eei66wof36n5e"

  describe "parse/1" do
    test "decodes a valid raw CID string to bytes" do
      assert {:ok, @raw_bytes} = DASL.CID.parse(@raw_cid)
    end

    test "decodes a valid drisl CID string to bytes" do
      assert {:ok, @drisl_bytes} = DASL.CID.parse(@drisl_cid)
    end

    test "errors when prefix is not 'b'" do
      assert {:error, "CID must start with 'b'"} = DASL.CID.parse("zQmSomeLegacyCID")
    end

    test "errors on invalid base32 content" do
      assert {:error, "invalid base32 encoding"} = DASL.CID.parse("b!!!!!")
    end

    test "errors on empty string" do
      assert {:error, "CID must start with 'b'"} = DASL.CID.parse("")
    end
  end

  describe "decode/1" do
    test "decodes raw bytes into fields" do
      assert {:ok, fields} = DASL.CID.decode(@raw_bytes)
      assert fields.version == 1
      assert fields.codec == :raw
      assert fields.hash_type == 0x12
      assert fields.hash_size == 32
      assert fields.digest == @digest
    end

    test "decodes drisl bytes into fields" do
      assert {:ok, fields} = DASL.CID.decode(@drisl_bytes)
      assert fields.codec == :drisl
    end

    test "errors on unsupported version" do
      bad = <<2, 0x55, 0x12, 0x20>> <> @digest
      assert {:error, "unsupported CID version: 2"} = DASL.CID.decode(bad)
    end

    test "errors on unsupported codec" do
      bad = <<1, 0xAB, 0x12, 0x20>> <> @digest
      assert {:error, "unsupported codec: 0xAB"} = DASL.CID.decode(bad)
    end

    test "errors on unsupported hash type" do
      bad = <<1, 0x55, 0x11, 0x20>> <> @digest
      assert {:error, "unsupported hash type: 0x11"} = DASL.CID.decode(bad)
    end

    test "errors on wrong hash size" do
      bad = <<1, 0x55, 0x12, 0x10>> <> @digest
      assert {:error, "invalid hash size: 16"} = DASL.CID.decode(bad)
    end

    test "errors on truncated digest" do
      bad = <<1, 0x55, 0x12, 0x20>> <> binary_part(@digest, 0, 16)
      assert {:error, "malformed CID bytes"} = DASL.CID.decode(bad)
    end

    test "errors on empty binary" do
      assert {:error, "malformed CID bytes"} = DASL.CID.decode(<<>>)
    end
  end

  describe "new/1" do
    test "constructs a CID struct from a raw CID string" do
      assert {:ok, cid} = DASL.CID.new(@raw_cid)
      assert %DASL.CID{} = cid
      assert cid.version == 1
      assert cid.codec == :raw
      assert cid.hash_type == 0x12
      assert cid.hash_size == 32
      assert cid.digest == @digest
      assert cid.bytes == @raw_bytes
    end

    test "constructs a CID struct from a drisl CID string" do
      assert {:ok, cid} = DASL.CID.new(@drisl_cid)
      assert cid.codec == :drisl
      assert cid.bytes == @drisl_bytes
    end

    test "propagates parse errors" do
      assert {:error, "CID must start with 'b'"} = DASL.CID.new("not-a-cid")
    end

    test "propagates decode errors" do
      bad_bytes = <<2, 0x55, 0x12, 0x20>> <> @digest
      bad_str = "b" <> Base.encode32(bad_bytes, case: :lower, padding: false)
      assert {:error, "unsupported CID version: 2"} = DASL.CID.new(bad_str)
    end
  end

  describe "new!/1" do
    test "returns a CID struct on a valid string" do
      assert %DASL.CID{} = DASL.CID.new!(@raw_cid)
    end

    test "returned struct matches new/1" do
      {:ok, expected} = DASL.CID.new(@raw_cid)
      assert DASL.CID.new!(@raw_cid) == expected
    end

    test "raises ArgumentError on an invalid prefix" do
      assert_raise ArgumentError, ~r/invalid CID 'not-a-cid'/, fn ->
        DASL.CID.new!("not-a-cid")
      end
    end

    test "raises ArgumentError on malformed base32" do
      assert_raise ArgumentError, ~r/invalid CID/, fn ->
        DASL.CID.new!("b!!!!!")
      end
    end

    test "raises ArgumentError on an invalid CID version embedded in the bytes" do
      bad_bytes = <<2, 0x55, 0x12, 0x20>> <> @digest
      bad_str = "b" <> Base.encode32(bad_bytes, case: :lower, padding: false)

      assert_raise ArgumentError, ~r/unsupported CID version/, fn ->
        DASL.CID.new!(bad_str)
      end
    end
  end

  describe "~CID sigil" do
    import DASL.CID, only: [sigil_CID: 2]

    test "constructs a CID struct from a literal string" do
      assert %DASL.CID{} =
               ~CID"bafkreifzjut3te2nhyekklss27nh3k72ysco7y32koao5eei66wof36n5e"
    end

    test "produced struct equals new!/1" do
      assert ~CID"bafkreifzjut3te2nhyekklss27nh3k72ysco7y32koao5eei66wof36n5e" ==
               DASL.CID.new!(@raw_cid)
    end

    test "codec is preserved for raw" do
      assert ~CID"bafkreifzjut3te2nhyekklss27nh3k72ysco7y32koao5eei66wof36n5e".codec == :raw
    end

    test "codec is preserved for drisl" do
      assert ~CID"bafyreifzjut3te2nhyekklss27nh3k72ysco7y32koao5eei66wof36n5e".codec == :drisl
    end

    test "round-trips through encode" do
      assert DASL.CID.encode(~CID"bafkreifzjut3te2nhyekklss27nh3k72ysco7y32koao5eei66wof36n5e") ==
               @raw_cid
    end

    test "raises ArgumentError on an invalid CID string" do
      assert_raise ArgumentError, ~r/invalid CID/, fn ->
        DASL.CID.sigil_CID("not-a-cid", [])
      end
    end
  end

  describe "encode/1" do
    test "round-trips a raw CID" do
      {:ok, cid} = DASL.CID.new(@raw_cid)
      assert DASL.CID.encode(cid) == @raw_cid
    end

    test "round-trips a drisl CID" do
      {:ok, cid} = DASL.CID.new(@drisl_cid)
      assert DASL.CID.encode(cid) == @drisl_cid
    end

    test "always starts with 'b'" do
      {:ok, cid} = DASL.CID.new(@raw_cid)
      assert String.starts_with?(DASL.CID.encode(cid), "b")
    end
  end

  describe "to_cbor/1" do
    test "wraps bytes in a tag-42 CBOR tag with null-byte prefix" do
      {:ok, cid} = DASL.CID.new(@raw_cid)
      tag = DASL.CID.to_cbor(cid)
      assert %CBOR.Tag{tag: 42, value: %CBOR.Tag{tag: :bytes, value: <<0, rest::binary>>}} = tag
      assert rest == @raw_bytes
    end
  end

  describe "from_cbor/1" do
    test "decodes a tag-42 CBOR CID into a struct" do
      {:ok, cid} = DASL.CID.new(@raw_cid)
      tag = DASL.CID.to_cbor(cid)
      assert {:ok, decoded} = DASL.CID.from_cbor(tag)
      assert %DASL.CID{} = decoded
      assert decoded.codec == :raw
      assert decoded.digest == @digest
      assert decoded.bytes == @raw_bytes
    end

    test "round-trips through CBOR and back to the same CID string" do
      {:ok, cid} = DASL.CID.new(@raw_cid)
      {:ok, decoded} = cid |> DASL.CID.to_cbor() |> DASL.CID.from_cbor()
      assert DASL.CID.encode(decoded) == @raw_cid
    end

    test "errors on wrong CBOR tag number" do
      tag = %CBOR.Tag{tag: 1, value: %CBOR.Tag{tag: :bytes, value: <<0>> <> @raw_bytes}}
      assert {:error, "invalid CBOR CID tag"} = DASL.CID.from_cbor(tag)
    end

    test "errors when null byte prefix is missing" do
      tag = %CBOR.Tag{tag: 42, value: %CBOR.Tag{tag: :bytes, value: @raw_bytes}}
      assert {:error, _} = DASL.CID.from_cbor(tag)
    end

    test "errors on non-tag input" do
      assert {:error, "invalid CBOR CID tag"} = DASL.CID.from_cbor("not a tag")
    end
  end

  describe "compute/2" do
    test "returns a valid CID struct" do
      cid = DASL.CID.compute("hello world")
      assert %DASL.CID{} = cid
      assert cid.version == 1
      assert cid.hash_type == 0x12
      assert cid.hash_size == 32
    end

    test "defaults to :raw codec" do
      cid = DASL.CID.compute("hello world")
      assert cid.codec == :raw
    end

    test "accepts :drisl codec" do
      cid = DASL.CID.compute("hello world", :drisl)
      assert cid.codec == :drisl
    end

    test "digest matches SHA-256 of input" do
      cid = DASL.CID.compute("hello world")
      assert cid.digest == @digest
    end

    test "produces the correct known CID string" do
      cid = DASL.CID.compute("hello world")
      assert DASL.CID.encode(cid) == @raw_cid
    end

    test "raw and drisl CIDs for the same data have different bytes" do
      raw = DASL.CID.compute("hello world", :raw)
      drisl = DASL.CID.compute("hello world", :drisl)
      assert raw.bytes != drisl.bytes
      assert raw.digest == drisl.digest
    end

    test "different inputs produce different CIDs" do
      a = DASL.CID.compute("foo")
      b = DASL.CID.compute("bar")
      assert a.digest != b.digest
    end

    test "round-trips through encode and new" do
      cid = DASL.CID.compute("hello world")
      {:ok, decoded} = cid |> DASL.CID.encode() |> DASL.CID.new()
      assert decoded.digest == cid.digest
      assert decoded.codec == cid.codec
    end
  end

  describe "verify?/2" do
    test "returns true when data matches the CID" do
      cid = DASL.CID.compute("hello world")
      assert DASL.CID.verify?(cid, "hello world")
    end

    test "returns false when data does not match" do
      cid = DASL.CID.compute("hello world")
      refute DASL.CID.verify?(cid, "goodbye world")
    end

    test "returns false for empty binary against non-empty CID" do
      cid = DASL.CID.compute("hello world")
      refute DASL.CID.verify?(cid, "")
    end

    test "returns true for empty binary when CID was computed from empty binary" do
      cid = DASL.CID.compute("")
      assert DASL.CID.verify?(cid, "")
    end

    test "codec does not affect verification — only the digest matters" do
      raw_cid = DASL.CID.compute("hello world", :raw)
      drisl_cid = DASL.CID.compute("hello world", :drisl)
      assert DASL.CID.verify?(raw_cid, "hello world")
      assert DASL.CID.verify?(drisl_cid, "hello world")
    end

    test "works with a CID decoded from a string" do
      {:ok, cid} = DASL.CID.new(@raw_cid)
      assert DASL.CID.verify?(cid, "hello world")
      refute DASL.CID.verify?(cid, "not hello world")
    end
  end
end
