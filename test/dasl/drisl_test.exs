defmodule DASL.DRISLTest do
  use ExUnit.Case, async: true

  doctest DASL.DRISL
  doctest DASL.DRISL.Decoder
  doctest DASL.DRISL.Encoder

  # SHA-256("hello world")
  @digest <<185, 77, 39, 185, 147, 77, 62, 8, 165, 46, 82, 215, 218, 125, 171, 250, 196, 132, 239,
            227, 122, 83, 128, 238, 144, 136, 247, 172, 226, 239, 205, 233>>

  @raw_cid "bafkreifzjut3te2nhyekklss27nh3k72ysco7y32koao5eei66wof36n5e"

  # Spec test vectors (Appendix B.3):
  # { "a": 0, "b": 1, "aa": 2 } => a361610061620162616103 (as map, hex)
  # [1, [2, 3], [4, 5]]         => 8301820203820405
  @spec_map_bytes Base.decode16!("a36161006162016261610 2" |> String.replace(" ", ""),
                    case: :lower
                  )
  @spec_array_bytes Base.decode16!("8301820203820405", case: :lower)

  # ──────────────────────────────────────────────────────────────────
  # Encoder
  # ──────────────────────────────────────────────────────────────────

  describe "encode/1 — primitives" do
    test "encodes nil" do
      assert {:ok, <<0xF6>>} = DASL.DRISL.encode(nil)
    end

    test "encodes true" do
      assert {:ok, <<0xF5>>} = DASL.DRISL.encode(true)
    end

    test "encodes false" do
      assert {:ok, <<0xF4>>} = DASL.DRISL.encode(false)
    end

    test "encodes small positive integer" do
      assert {:ok, <<0x00>>} = DASL.DRISL.encode(0)
      assert {:ok, <<0x17>>} = DASL.DRISL.encode(23)
    end

    test "encodes one-byte positive integer" do
      assert {:ok, <<0x18, 0x18>>} = DASL.DRISL.encode(24)
      assert {:ok, <<0x18, 0xFF>>} = DASL.DRISL.encode(255)
    end

    test "encodes negative integer" do
      assert {:ok, <<0x20>>} = DASL.DRISL.encode(-1)
      assert {:ok, <<0x37>>} = DASL.DRISL.encode(-24)
    end

    test "encodes float as 64-bit IEEE 754" do
      assert {:ok, <<0xFB, _::binary-size(8)>>} = DASL.DRISL.encode(1.5)
    end

    test "float encoding round-trips through decode" do
      {:ok, bin} = DASL.DRISL.encode(1.5)
      assert {:ok, 1.5, ""} = DASL.DRISL.decode(bin)
    end

    test "encodes text string" do
      assert {:ok, <<0x61, 0x61>>} = DASL.DRISL.encode("a")
      assert {:ok, <<0x62, 0x61, 0x61>>} = DASL.DRISL.encode("aa")
    end

    test "encodes empty string" do
      assert {:ok, <<0x60>>} = DASL.DRISL.encode("")
    end
  end

  describe "encode/1 — arrays" do
    test "encodes empty array" do
      assert {:ok, <<0x80>>} = DASL.DRISL.encode([])
    end

    test "encodes simple array" do
      assert {:ok, <<0x83, 0x01, 0x02, 0x03>>} = DASL.DRISL.encode([1, 2, 3])
    end

    test "matches spec test vector for nested arrays" do
      assert {:ok, @spec_array_bytes} = DASL.DRISL.encode([[1, [2, 3], [4, 5]]] |> hd())
      assert {:ok, @spec_array_bytes} = DASL.DRISL.encode([1, [2, 3], [4, 5]])
    end

    test "encodes nested arrays" do
      {:ok, bin} = DASL.DRISL.encode([1, [2, 3], [4, 5]])
      assert {:ok, [1, [2, 3], [4, 5]], ""} = DASL.DRISL.decode(bin)
    end
  end

  describe "encode/1 — maps" do
    test "encodes empty map" do
      assert {:ok, <<0xA0>>} = DASL.DRISL.encode(%{})
    end

    test "encodes single-entry map" do
      assert {:ok, <<0xA1, 0x61, 0x61, 0x01>>} = DASL.DRISL.encode(%{"a" => 1})
    end

    test "sorts map keys by encoded length then lexicographically" do
      # Spec example: {"a": 0, "b": 1, "aa": 2} must encode in that order
      assert {:ok, @spec_map_bytes} = DASL.DRISL.encode(%{"aa" => 2, "b" => 1, "a" => 0})
    end

    test "rejects non-string map keys" do
      assert {:error, :non_string_map_key} = DASL.DRISL.encode(%{1 => "x"})
      assert {:error, :non_string_map_key} = DASL.DRISL.encode(%{:atom => "x"})
    end

    test "encodes nested map" do
      {:ok, bin} = DASL.DRISL.encode(%{"outer" => %{"inner" => 42}})
      assert {:ok, %{"outer" => %{"inner" => 42}}, ""} = DASL.DRISL.decode(bin)
    end
  end

  describe "encode/1 — CIDs" do
    test "encodes a CID as CBOR tag 42" do
      {:ok, cid} = DASL.CID.new(@raw_cid)
      {:ok, bin} = DASL.DRISL.encode(cid)
      # Tag 42 is major type 6, value 42 => 0xd8 0x2a
      assert <<0xD8, 0x2A, _::binary>> = bin
    end

    test "CID survives encode → decode round-trip" do
      {:ok, cid} = DASL.CID.new(@raw_cid)
      {:ok, bin} = DASL.DRISL.encode(cid)
      assert {:ok, %DASL.CID{} = decoded_cid, ""} = DASL.DRISL.decode(bin)
      assert DASL.CID.encode(decoded_cid) == @raw_cid
    end

    test "CID in a map survives round-trip" do
      {:ok, cid} = DASL.CID.new(@raw_cid)
      {:ok, bin} = DASL.DRISL.encode(%{"link" => cid})
      assert {:ok, %{"link" => %DASL.CID{} = decoded_cid}, ""} = DASL.DRISL.decode(bin)
      assert decoded_cid.digest == @digest
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # Decoder
  # ──────────────────────────────────────────────────────────────────

  describe "decode/1 — valid inputs" do
    test "decodes integers" do
      assert {:ok, 0, ""} = DASL.DRISL.decode(<<0x00>>)
      assert {:ok, -1, ""} = DASL.DRISL.decode(<<0x20>>)
      assert {:ok, 255, ""} = DASL.DRISL.decode(<<0x18, 0xFF>>)
    end

    test "decodes booleans and null" do
      assert {:ok, true, ""} = DASL.DRISL.decode(<<0xF5>>)
      assert {:ok, false, ""} = DASL.DRISL.decode(<<0xF4>>)
      assert {:ok, nil, ""} = DASL.DRISL.decode(<<0xF6>>)
    end

    test "decodes a text string" do
      assert {:ok, "hello", ""} = DASL.DRISL.decode(<<0x65, "hello">>)
    end

    test "decodes a 64-bit float" do
      # 1.5 as float64: 0xfb 3ff8000000000000
      bin = <<0xFB, 0x3F, 0xF8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>>
      assert {:ok, 1.5, ""} = DASL.DRISL.decode(bin)
    end

    test "decodes a CID tag 42 into a %DASL.CID{}" do
      {:ok, cid} = DASL.CID.new(@raw_cid)
      cbor_tag = DASL.CID.to_cbor(cid)
      tag_bytes = CBOR.encode(cbor_tag)
      assert {:ok, %DASL.CID{}, ""} = DASL.DRISL.decode(tag_bytes)
    end

    test "returns remaining bytes" do
      assert {:ok, 1, <<2>>} = DASL.DRISL.decode(<<0x01, 0x02>>)
    end
  end

  describe "decode/1 — spec compliance rejections" do
    test "rejects half-precision float (0xf9)" do
      # 0.0 as half-precision
      assert {:error, :half_precision_float} = DASL.DRISL.decode(<<0xF9, 0x00, 0x00>>)
    end

    test "rejects single-precision float (0xfa)" do
      # 1.5 as single-precision
      assert {:error, :single_precision_float} =
               DASL.DRISL.decode(<<0xFA, 0x3F, 0xC0, 0x00, 0x00>>)
    end

    test "rejects CBOR tag 0 (datetime)" do
      # Build raw CBOR: tag(0) + text string "2025-03-30T12:24:16Z"
      # tag 0 = 0xC0, then a tstr
      date_str = "2025-03-30T12:24:16Z"
      bin = <<0xC0, 0x74>> <> date_str
      assert {:error, :forbidden_tag} = DASL.DRISL.decode(bin)
    end

    test "rejects CBOR tag 1 (epoch time)" do
      bin = CBOR.encode(%CBOR.Tag{tag: 1, value: 1_000_000})
      assert {:error, :forbidden_tag} = DASL.DRISL.decode(bin)
    end

    test "rejects non-string map keys" do
      # Map with integer key: {1 => "x"}
      bin = <<0xA1, 0x01, 0x61, 0x78>>
      assert {:error, :non_string_map_key} = DASL.DRISL.decode(bin)
    end

    test "rejects simple values other than true/false/null" do
      # simple(16) = 0xF0
      bin = <<0xF0>>
      assert {:error, _} = DASL.DRISL.decode(bin)
    end

    test "rejects non-finite float :inf" do
      # CBOR lib encodes :inf as 0xf9 (half-precision) — caught as :half_precision_float
      bin = CBOR.encode(%CBOR.Tag{tag: :float, value: :inf})
      assert {:error, reason} = DASL.DRISL.decode(bin)
      assert reason in [:half_precision_float, :forbidden_float]
    end

    test "rejects non-finite float :-inf" do
      bin = CBOR.encode(%CBOR.Tag{tag: :float, value: :"-inf"})
      assert {:error, reason} = DASL.DRISL.decode(bin)
      assert reason in [:half_precision_float, :forbidden_float]
    end

    test "rejects non-finite float :nan" do
      bin = CBOR.encode(%CBOR.Tag{tag: :float, value: :nan})
      assert {:error, reason} = DASL.DRISL.decode(bin)
      assert reason in [:half_precision_float, :forbidden_float]
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # Round-trip
  # ──────────────────────────────────────────────────────────────────

  describe "encode/decode round-trip" do
    test "integer" do
      for n <- [0, -1, 23, 24, 255, 256, 65535, -65536, 4_294_967_295] do
        {:ok, bin} = DASL.DRISL.encode(n)
        assert {:ok, ^n, ""} = DASL.DRISL.decode(bin), "failed for #{n}"
      end
    end

    test "bignum" do
      n = 18_446_744_073_709_551_616
      {:ok, bin} = DASL.DRISL.encode(n)
      assert {:ok, ^n, ""} = DASL.DRISL.decode(bin)
    end

    test "string" do
      for s <- ["", "a", "hello", "🚀 science"] do
        {:ok, bin} = DASL.DRISL.encode(s)
        assert {:ok, ^s, ""} = DASL.DRISL.decode(bin), "failed for #{inspect(s)}"
      end
    end

    test "nested map preserves structure" do
      term = %{"x" => [1, 2, %{"y" => true, "z" => nil}]}
      {:ok, bin} = DASL.DRISL.encode(term)
      assert {:ok, ^term, ""} = DASL.DRISL.decode(bin)
    end

    test "map key ordering is deterministic" do
      term = %{"aa" => 2, "b" => 1, "a" => 0}
      {:ok, bin1} = DASL.DRISL.encode(term)
      {:ok, bin2} = DASL.DRISL.encode(term)
      assert bin1 == bin2
    end
  end
end
