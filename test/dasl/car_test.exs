defmodule DASL.CARTest do
  use ExUnit.Case, async: true

  alias DASL.{CAR, CID, DRISL}
  alias Varint.LEB128

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Builds a minimal valid CAR binary from scratch, bypassing the encoder, so
  # decoder tests aren't coupled to the encoder's correctness.
  defp build_car_binary(roots, blocks) do
    {:ok, header_bin} = DRISL.encode(%{"version" => 1, "roots" => roots})
    header = LEB128.encode(byte_size(header_bin)) <> header_bin

    body =
      Enum.reduce(blocks, <<>>, fn {%CID{bytes: cid_bytes}, data}, acc ->
        length = byte_size(cid_bytes) + byte_size(data)
        acc <> LEB128.encode(length) <> cid_bytes <> data
      end)

    header <> body
  end

  # ---------------------------------------------------------------------------
  # Round-trip — encode / decode
  # ---------------------------------------------------------------------------

  describe "round-trip" do
    test "single block, no roots" do
      data = "hello world"
      cid = CID.compute(data)
      car = %CAR{version: 1, roots: [], blocks: %{cid => data}}

      assert {:ok, encoded} = CAR.encode(car)
      assert {:ok, decoded} = CAR.decode(encoded)

      assert decoded.version == 1
      assert decoded.roots == []
      assert Map.fetch!(decoded.blocks, cid) == data
    end

    test "multiple blocks with a root" do
      data1 = "block one"
      data2 = "block two"
      cid1 = CID.compute(data1)
      cid2 = CID.compute(data2)
      car = %CAR{version: 1, roots: [cid1], blocks: %{cid1 => data1, cid2 => data2}}

      assert {:ok, encoded} = CAR.encode(car)
      assert {:ok, decoded} = CAR.decode(encoded)

      assert decoded.roots == [cid1]
      assert Map.fetch!(decoded.blocks, cid1) == data1
      assert Map.fetch!(decoded.blocks, cid2) == data2
    end

    test "empty blocks" do
      car = %CAR{version: 1, roots: [], blocks: %{}}

      assert {:ok, encoded} = CAR.encode(car)
      assert {:ok, decoded} = CAR.decode(encoded)

      assert decoded.blocks == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Decoder — verify: true (default)
  # ---------------------------------------------------------------------------

  describe "decode with verify: true (default)" do
    test "returns :cid_mismatch when block data has been tampered" do
      data = "legitimate data"
      cid = CID.compute(data)
      tampered = "tampered data!!"

      car_bin = build_car_binary([], [{cid, tampered}])

      assert {:error, :block, :cid_mismatch} = CAR.decode(car_bin)
    end

    test "accepts correct data" do
      data = "correct data"
      cid = CID.compute(data)
      car_bin = build_car_binary([], [{cid, data}])

      assert {:ok, _} = CAR.decode(car_bin)
    end
  end

  # ---------------------------------------------------------------------------
  # Decoder — verify: false
  # ---------------------------------------------------------------------------

  describe "decode with verify: false" do
    test "passes tampered block data through without error" do
      data = "legitimate data"
      cid = CID.compute(data)
      tampered = "tampered data!!"

      car_bin = build_car_binary([], [{cid, tampered}])

      assert {:ok, decoded} = CAR.decode(car_bin, verify: false)
      assert Map.fetch!(decoded.blocks, cid) == tampered
    end
  end

  # ---------------------------------------------------------------------------
  # Encoder — verify: true (default)
  # ---------------------------------------------------------------------------

  describe "encode with verify: true (default)" do
    test "returns :cid_mismatch when a block CID does not match its data" do
      wrong_cid = CID.compute("something else entirely")
      car = %CAR{version: 1, roots: [], blocks: %{wrong_cid => "this is the actual data"}}

      assert {:error, :block, :cid_mismatch} = CAR.encode(car)
    end

    test "accepts blocks where the CID matches the data" do
      data = "correct data"
      cid = CID.compute(data)
      car = %CAR{version: 1, roots: [], blocks: %{cid => data}}

      assert {:ok, _} = CAR.encode(car)
    end
  end

  # ---------------------------------------------------------------------------
  # Encoder — verify: false
  # ---------------------------------------------------------------------------

  describe "encode with verify: false" do
    test "writes a mismatched CID without error" do
      wrong_cid = CID.compute("not this data")
      car = %CAR{version: 1, roots: [], blocks: %{wrong_cid => "this is the actual data"}}

      assert {:ok, bin} = CAR.encode(car, verify: false)
      assert is_binary(bin)
    end
  end

  # ---------------------------------------------------------------------------
  # Decoder — header errors
  # ---------------------------------------------------------------------------

  describe "decode header errors" do
    test "zero-length header returns :empty" do
      binary = LEB128.encode(0) <> <<>>
      assert {:error, :header, :empty} = CAR.decode(binary)
    end

    test "header without version key returns :missing_version" do
      {:ok, no_version} = DRISL.encode(%{"roots" => []})
      binary = LEB128.encode(byte_size(no_version)) <> no_version
      assert {:error, :header, :missing_version} = CAR.decode(binary)
    end

    test "header without roots key returns :missing_roots" do
      {:ok, no_roots} = DRISL.encode(%{"version" => 1})
      binary = LEB128.encode(byte_size(no_roots)) <> no_roots
      assert {:error, :header, :missing_roots} = CAR.decode(binary)
    end

    test "header with unsupported version returns :unsupported_version" do
      {:ok, bad_version} = DRISL.encode(%{"version" => 2, "roots" => []})
      binary = LEB128.encode(byte_size(bad_version)) <> bad_version
      assert {:error, :header, :unsupported_version} = CAR.decode(binary)
    end

    test "header with non-CID root returns :invalid_roots" do
      {:ok, bad_roots} = DRISL.encode(%{"version" => 1, "roots" => ["not-a-cid"]})
      binary = LEB128.encode(byte_size(bad_roots)) <> bad_roots
      assert {:error, :header, :invalid_roots} = CAR.decode(binary)
    end
  end

  # ---------------------------------------------------------------------------
  # Decoder — block errors
  # ---------------------------------------------------------------------------

  describe "decode block errors" do
    test "block with varint length < 36 returns :too_short" do
      {:ok, header_bin} = DRISL.encode(%{"version" => 1, "roots" => []})
      header = LEB128.encode(byte_size(header_bin)) <> header_bin
      short_block = LEB128.encode(10) <> :binary.copy(<<0>>, 10)

      assert {:error, :block, :too_short} = CAR.decode(header <> short_block)
    end
  end

  # ---------------------------------------------------------------------------
  # add_block/2
  # ---------------------------------------------------------------------------

  describe "add_block/2" do
    test "computes and stores the CID, returns the updated car and CID" do
      car = %CAR{version: 1, roots: [], blocks: %{}}
      data = "some raw data"

      {updated_car, cid} = CAR.add_block(car, data)

      assert Map.fetch!(updated_car.blocks, cid) == data
      assert cid == CID.compute(data, :raw)
    end

    test "computed CID verifies against the stored data" do
      {updated_car, cid} = CAR.add_block(%CAR{version: 1, roots: [], blocks: %{}}, "data")

      assert CID.verify?(cid, Map.fetch!(updated_car.blocks, cid))
    end

    test "CID uses :raw codec" do
      {_, cid} = CAR.add_block(%CAR{version: 1, roots: [], blocks: %{}}, "data")

      assert cid.codec == :raw
    end
  end

  # ---------------------------------------------------------------------------
  # add_root/2
  # ---------------------------------------------------------------------------

  describe "add_root/2" do
    test "adds a CID to roots when it exists in blocks" do
      data = "block data"
      {car, cid} = CAR.add_block(%CAR{version: 1, roots: [], blocks: %{}}, data)

      assert {:ok, updated_car} = CAR.add_root(car, cid)
      assert cid in updated_car.roots
    end

    test "returns :not_in_blocks when CID is not in blocks" do
      car = %CAR{version: 1, roots: [], blocks: %{}}
      cid = CID.compute("ghost block")

      assert {:error, :not_in_blocks} = CAR.add_root(car, cid)
    end

    test "no-ops when the CID is already a root" do
      data = "block data"
      {car, cid} = CAR.add_block(%CAR{version: 1, roots: [], blocks: %{}}, data)
      {:ok, car_with_root} = CAR.add_root(car, cid)

      assert {:ok, ^car_with_root} = CAR.add_root(car_with_root, cid)
      assert length(car_with_root.roots) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # remove_root/2
  # ---------------------------------------------------------------------------

  describe "remove_root/2" do
    test "removes a CID from roots" do
      data = "block data"
      {car, cid} = CAR.add_block(%CAR{version: 1, roots: [], blocks: %{}}, data)
      {:ok, car_with_root} = CAR.add_root(car, cid)

      updated_car = CAR.remove_root(car_with_root, cid)

      refute cid in updated_car.roots
    end

    test "no-ops when CID is not in roots" do
      car = %CAR{version: 1, roots: [], blocks: %{}}
      cid = CID.compute("not a root")

      assert CAR.remove_root(car, cid) == car
    end
  end

  # ---------------------------------------------------------------------------
  # remove_block/2
  # ---------------------------------------------------------------------------

  describe "remove_block/2" do
    test "removes a block that is not a root" do
      data = "removable block"
      {car, cid} = CAR.add_block(%CAR{version: 1, roots: [], blocks: %{}}, data)

      assert {:ok, updated_car} = CAR.remove_block(car, cid)
      refute Map.has_key?(updated_car.blocks, cid)
    end

    test "returns :is_a_root when the CID is a root" do
      data = "root block"
      {car, cid} = CAR.add_block(%CAR{version: 1, roots: [], blocks: %{}}, data)
      {:ok, car_with_root} = CAR.add_root(car, cid)

      assert {:error, :is_a_root} = CAR.remove_block(car_with_root, cid)
    end

    test "no-ops when CID is not in blocks" do
      car = %CAR{version: 1, roots: [], blocks: %{}}
      cid = CID.compute("non-existent")

      assert {:ok, ^car} = CAR.remove_block(car, cid)
    end
  end
end
