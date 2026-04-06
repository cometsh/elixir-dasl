defmodule DASL.CAR.DRISLTest do
  use ExUnit.Case, async: true

  alias DASL.{CID, DRISL}
  alias DASL.CAR.DRISL, as: DrislCAR
  alias Varint.LEB128

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Builds a raw CAR binary with DRISL-encoded block data, bypassing the
  # encoder so decode tests aren't coupled to encode correctness.
  defp build_drisl_car_binary(roots, blocks) do
    {:ok, header_bin} = DRISL.encode(%{"version" => 1, "roots" => roots})
    header = LEB128.encode(byte_size(header_bin)) <> header_bin

    body =
      Enum.reduce(blocks, <<>>, fn {%CID{bytes: cid_bytes}, term}, acc ->
        {:ok, encoded} = DRISL.encode(term)
        length = byte_size(cid_bytes) + byte_size(encoded)
        acc <> LEB128.encode(length) <> cid_bytes <> encoded
      end)

    header <> body
  end

  # ---------------------------------------------------------------------------
  # Round-trip — encode / decode
  # ---------------------------------------------------------------------------

  describe "round-trip" do
    test "single DRISL term block, no roots" do
      term = %{"key" => 42, "flag" => true}
      {:ok, encoded} = DRISL.encode(term)
      cid = CID.compute(encoded, :drisl)

      car = %DrislCAR{version: 1, roots: [], blocks: %{cid => term}}

      assert {:ok, car_bin} = DrislCAR.encode(car)
      assert {:ok, decoded} = DrislCAR.decode(car_bin)

      assert decoded.version == 1
      assert decoded.roots == []
      assert Map.fetch!(decoded.blocks, cid) == term
    end

    test "multiple blocks with a root" do
      term1 = %{"id" => 1}
      term2 = [1, 2, 3]

      {:ok, enc1} = DRISL.encode(term1)
      {:ok, enc2} = DRISL.encode(term2)
      cid1 = CID.compute(enc1, :drisl)
      cid2 = CID.compute(enc2, :drisl)

      car = %DrislCAR{version: 1, roots: [cid1], blocks: %{cid1 => term1, cid2 => term2}}

      assert {:ok, car_bin} = DrislCAR.encode(car)
      assert {:ok, decoded} = DrislCAR.decode(car_bin)

      assert decoded.roots == [cid1]
      assert Map.fetch!(decoded.blocks, cid1) == term1
      assert Map.fetch!(decoded.blocks, cid2) == term2
    end

    test "empty blocks" do
      car = %DrislCAR{version: 1, roots: [], blocks: %{}}

      assert {:ok, car_bin} = DrislCAR.encode(car)
      assert {:ok, decoded} = DrislCAR.decode(car_bin)

      assert decoded.blocks == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Decoder — verify: true (default)
  # ---------------------------------------------------------------------------

  describe "decode with verify: true (default)" do
    test "returns :cid_mismatch when block data has been tampered" do
      term = %{"legit" => true}
      {:ok, encoded} = DRISL.encode(term)
      cid = CID.compute(encoded, :drisl)

      tampered_term = %{"legit" => false}
      {:ok, tampered_encoded} = DRISL.encode(tampered_term)

      car_bin = build_drisl_car_binary([], [{cid, tampered_term}])

      # verify the tampered binary is actually different so this test is meaningful
      assert tampered_encoded != encoded
      assert {:error, :block, :cid_mismatch} = DrislCAR.decode(car_bin)
    end

    test "accepts correct data" do
      term = %{"correct" => true}
      {:ok, encoded} = DRISL.encode(term)
      cid = CID.compute(encoded, :drisl)

      car_bin = build_drisl_car_binary([], [{cid, term}])

      assert {:ok, _} = DrislCAR.decode(car_bin)
    end
  end

  # ---------------------------------------------------------------------------
  # Decoder — verify: false
  # ---------------------------------------------------------------------------

  describe "decode with verify: false" do
    test "passes tampered block data through without error" do
      term = %{"legit" => true}
      {:ok, encoded} = DRISL.encode(term)
      cid = CID.compute(encoded, :drisl)

      tampered_term = %{"legit" => false}
      car_bin = build_drisl_car_binary([], [{cid, tampered_term}])

      assert {:ok, decoded} = DrislCAR.decode(car_bin, verify: false)
      assert Map.fetch!(decoded.blocks, cid) == tampered_term
    end
  end

  # ---------------------------------------------------------------------------
  # Encoder — verify: true (default)
  # ---------------------------------------------------------------------------

  describe "encode with verify: true (default)" do
    test "returns :cid_mismatch when a block CID does not match its term" do
      wrong_cid = CID.compute("unrelated data", :drisl)
      car = %DrislCAR{version: 1, roots: [], blocks: %{wrong_cid => %{"actual" => "term"}}}

      assert {:error, :block, :cid_mismatch} = DrislCAR.encode(car)
    end

    test "accepts blocks where CID matches the DRISL-encoded term" do
      term = %{"valid" => true}
      {:ok, encoded} = DRISL.encode(term)
      cid = CID.compute(encoded, :drisl)
      car = %DrislCAR{version: 1, roots: [], blocks: %{cid => term}}

      assert {:ok, _} = DrislCAR.encode(car)
    end
  end

  # ---------------------------------------------------------------------------
  # Encoder — verify: false
  # ---------------------------------------------------------------------------

  describe "encode with verify: false" do
    test "writes a mismatched CID without error" do
      wrong_cid = CID.compute("unrelated", :drisl)
      car = %DrislCAR{version: 1, roots: [], blocks: %{wrong_cid => %{"data" => 1}}}

      assert {:ok, bin} = DrislCAR.encode(car, verify: false)
      assert is_binary(bin)
    end
  end

  # ---------------------------------------------------------------------------
  # add_block/2
  # ---------------------------------------------------------------------------

  describe "add_block/2" do
    test "DRISL-encodes the term, computes CID on encoded form, stores original term" do
      car = %DrislCAR{version: 1, roots: [], blocks: %{}}
      term = %{"hello" => "world"}

      assert {:ok, {updated_car, cid}} = DrislCAR.add_block(car, term)

      assert Map.fetch!(updated_car.blocks, cid) == term
    end

    test "CID uses :drisl codec" do
      {:ok, {_, cid}} =
        DrislCAR.add_block(%DrislCAR{version: 1, roots: [], blocks: %{}}, %{"a" => 1})

      assert cid.codec == :drisl
    end

    test "CID verifies against the DRISL-encoded form of the term" do
      term = %{"verifiable" => true}

      {:ok, {_, cid}} =
        DrislCAR.add_block(%DrislCAR{version: 1, roots: [], blocks: %{}}, term)

      {:ok, encoded} = DRISL.encode(term)
      assert CID.verify?(cid, encoded)
    end

    test "CID does not verify against the raw term representation" do
      term = %{"verifiable" => true}

      {:ok, {_, cid}} =
        DrislCAR.add_block(%DrislCAR{version: 1, roots: [], blocks: %{}}, term)

      refute CID.verify?(cid, :erlang.term_to_binary(term))
    end

    test "returns error when term cannot be DRISL-encoded" do
      car = %DrislCAR{version: 1, roots: [], blocks: %{}}

      assert {:error, _} = DrislCAR.add_block(car, %{1 => "non-string key"})
    end
  end

  # ---------------------------------------------------------------------------
  # add_root/2
  # ---------------------------------------------------------------------------

  describe "add_root/2" do
    test "adds a CID to roots when it exists in blocks" do
      {:ok, {car, cid}} =
        DrislCAR.add_block(%DrislCAR{version: 1, roots: [], blocks: %{}}, %{"x" => 1})

      assert {:ok, updated_car} = DrislCAR.add_root(car, cid)
      assert cid in updated_car.roots
    end

    test "returns :not_in_blocks when CID is not in blocks" do
      car = %DrislCAR{version: 1, roots: [], blocks: %{}}
      cid = CID.compute("ghost", :drisl)

      assert {:error, :not_in_blocks} = DrislCAR.add_root(car, cid)
    end

    test "no-ops when the CID is already a root" do
      {:ok, {car, cid}} =
        DrislCAR.add_block(%DrislCAR{version: 1, roots: [], blocks: %{}}, %{"x" => 1})

      {:ok, car_with_root} = DrislCAR.add_root(car, cid)

      assert {:ok, ^car_with_root} = DrislCAR.add_root(car_with_root, cid)
      assert length(car_with_root.roots) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # remove_root/2
  # ---------------------------------------------------------------------------

  describe "remove_root/2" do
    test "removes a CID from roots" do
      {:ok, {car, cid}} =
        DrislCAR.add_block(%DrislCAR{version: 1, roots: [], blocks: %{}}, %{"x" => 1})

      {:ok, car_with_root} = DrislCAR.add_root(car, cid)
      updated_car = DrislCAR.remove_root(car_with_root, cid)

      refute cid in updated_car.roots
    end

    test "no-ops when CID is not in roots" do
      car = %DrislCAR{version: 1, roots: [], blocks: %{}}
      cid = CID.compute("not a root", :drisl)

      assert DrislCAR.remove_root(car, cid) == car
    end
  end

  # ---------------------------------------------------------------------------
  # remove_block/2
  # ---------------------------------------------------------------------------

  describe "remove_block/2" do
    test "removes a block that is not a root" do
      {:ok, {car, cid}} =
        DrislCAR.add_block(%DrislCAR{version: 1, roots: [], blocks: %{}}, %{"data" => 1})

      assert {:ok, updated_car} = DrislCAR.remove_block(car, cid)
      refute Map.has_key?(updated_car.blocks, cid)
    end

    test "returns :is_a_root when the CID is a root" do
      {:ok, {car, cid}} =
        DrislCAR.add_block(%DrislCAR{version: 1, roots: [], blocks: %{}}, %{"data" => 1})

      {:ok, car_with_root} = DrislCAR.add_root(car, cid)

      assert {:error, :is_a_root} = DrislCAR.remove_block(car_with_root, cid)
    end

    test "no-ops when CID is not in blocks" do
      car = %DrislCAR{version: 1, roots: [], blocks: %{}}
      cid = CID.compute("non-existent", :drisl)

      assert {:ok, ^car} = DrislCAR.remove_block(car, cid)
    end
  end
end
