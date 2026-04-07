defmodule DASL.CAR.StreamDecoderTest do
  use ExUnit.Case, async: true

  alias DASL.{CAR, CID, DRISL}
  alias DASL.CAR.DRISL, as: DrislCAR
  alias Varint.LEB128

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

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

  # Splits a binary into chunks of the given size.
  defp chunk(binary, size) do
    binary
    |> :binary.bin_to_list()
    |> Enum.chunk_every(size)
    |> Enum.map(&:binary.list_to_bin/1)
  end

  # Collects a stream into {header, blocks} for easy assertions.
  defp collect(stream) do
    Enum.reduce(stream, {nil, []}, fn
      {:header, version, roots}, {nil, blocks} ->
        {{version, roots}, blocks}

      {:block, cid, data}, {header, blocks} ->
        {header, blocks ++ [{cid, data}]}
    end)
  end

  # ---------------------------------------------------------------------------
  # DASL.CAR.stream_decode/2 — single-chunk (entire binary as one element)
  # ---------------------------------------------------------------------------

  describe "CAR.stream_decode/2 — single chunk" do
    test "empty blocks" do
      car_bin = build_car_binary([], [])
      {{1, []}, []} = collect(CAR.stream_decode([car_bin]))
    end

    test "single block, no roots" do
      data = "hello stream"
      cid = CID.compute(data)
      car_bin = build_car_binary([], [{cid, data}])

      {{1, []}, [{decoded_cid, decoded_data}]} = collect(CAR.stream_decode([car_bin]))

      assert decoded_cid == cid
      assert decoded_data == data
    end

    test "multiple blocks with a root" do
      data1 = "block one"
      data2 = "block two"
      cid1 = CID.compute(data1)
      cid2 = CID.compute(data2)
      car_bin = build_car_binary([cid1], [{cid1, data1}, {cid2, data2}])

      {{1, [root]}, blocks} = collect(CAR.stream_decode([car_bin]))

      assert root == cid1
      assert length(blocks) == 2
      assert Enum.find(blocks, fn {c, _} -> c == cid1 end) |> elem(1) == data1
      assert Enum.find(blocks, fn {c, _} -> c == cid2 end) |> elem(1) == data2
    end

    test "header carries version and roots" do
      data = "data"
      cid = CID.compute(data)
      car_bin = build_car_binary([cid], [{cid, data}])

      {{version, roots}, _} = collect(CAR.stream_decode([car_bin]))
      assert version == 1
      assert roots == [cid]
    end
  end

  # ---------------------------------------------------------------------------
  # Multi-chunk — chunk boundaries at various points
  # ---------------------------------------------------------------------------

  describe "CAR.stream_decode/2 — multi-chunk" do
    test "1-byte chunks (extreme case)" do
      data = "streamed one byte at a time"
      cid = CID.compute(data)
      car_bin = build_car_binary([], [{cid, data}])

      {{1, []}, [{decoded_cid, decoded_data}]} =
        car_bin |> chunk(1) |> CAR.stream_decode() |> collect()

      assert decoded_cid == cid
      assert decoded_data == data
    end

    test "2-byte chunks (splits varints mid-byte)" do
      data = "two byte chunks"
      cid = CID.compute(data)
      car_bin = build_car_binary([], [{cid, data}])

      {{1, []}, [{decoded_cid, decoded_data}]} =
        car_bin |> chunk(2) |> CAR.stream_decode() |> collect()

      assert decoded_cid == cid
      assert decoded_data == data
    end

    test "13-byte chunks (arbitrary mid-frame splits)" do
      data = "thirteen bytes per chunk in this test"
      cid = CID.compute(data)
      car_bin = build_car_binary([], [{cid, data}])

      {{1, []}, [{decoded_cid, decoded_data}]} =
        car_bin |> chunk(13) |> CAR.stream_decode() |> collect()

      assert decoded_cid == cid
      assert decoded_data == data
    end

    test "multiple blocks split across chunk boundaries" do
      blocks =
        for i <- 1..5,
            do:
              (
                data = "block #{i}"
                {CID.compute(data), data}
              )

      roots = [blocks |> hd() |> elem(0)]
      car_bin = build_car_binary(roots, blocks)

      {{1, _roots}, decoded_blocks} =
        car_bin |> chunk(7) |> CAR.stream_decode() |> collect()

      assert length(decoded_blocks) == 5

      for {cid, data} <- blocks do
        assert Enum.find(decoded_blocks, fn {c, _} -> c == cid end) |> elem(1) == data
      end
    end

    test "round-trips through encode/decode with chunking" do
      data = "round trip data"
      cid = CID.compute(data)
      car = %CAR{version: 1, roots: [cid], blocks: %{cid => data}}
      {:ok, car_bin} = CAR.encode(car)

      {{1, [root]}, [{decoded_cid, decoded_data}]} =
        car_bin |> chunk(10) |> CAR.stream_decode() |> collect()

      assert root == cid
      assert decoded_cid == cid
      assert decoded_data == data
    end
  end

  # ---------------------------------------------------------------------------
  # verify option
  # ---------------------------------------------------------------------------

  describe "CAR.stream_decode/2 — verify option" do
    test "raises on CID mismatch when verify: true (default)" do
      data = "legitimate data"
      cid = CID.compute(data)
      tampered = "tampered data!!"
      car_bin = build_car_binary([], [{cid, tampered}])

      assert_raise RuntimeError, ~r/CID mismatch/, fn ->
        CAR.stream_decode([car_bin]) |> Enum.to_list()
      end
    end

    test "passes through tampered data when verify: false" do
      data = "legitimate data"
      cid = CID.compute(data)
      tampered = "tampered data!!"
      car_bin = build_car_binary([], [{cid, tampered}])

      {{1, []}, [{_, decoded_data}]} =
        CAR.stream_decode([car_bin], verify: false) |> collect()

      assert decoded_data == tampered
    end
  end

  # ---------------------------------------------------------------------------
  # Error cases
  # ---------------------------------------------------------------------------

  describe "CAR.stream_decode/2 — error cases" do
    test "raises on truncated stream (incomplete block)" do
      data = "complete data"
      cid = CID.compute(data)
      car_bin = build_car_binary([], [{cid, data}])
      # Chop off the last 5 bytes so the final block frame is incomplete
      truncated = binary_part(car_bin, 0, byte_size(car_bin) - 5)

      assert_raise RuntimeError, ~r/unprocessed bytes/, fn ->
        CAR.stream_decode([truncated]) |> Enum.to_list()
      end
    end

    test "raises on invalid header (wrong version)" do
      {:ok, bad_header} = DRISL.encode(%{"version" => 99, "roots" => []})
      binary = LEB128.encode(byte_size(bad_header)) <> bad_header

      assert_raise RuntimeError, ~r/unsupported version/, fn ->
        CAR.stream_decode([binary]) |> Enum.to_list()
      end
    end

    test "raises on invalid header (missing roots)" do
      {:ok, no_roots} = DRISL.encode(%{"version" => 1})
      binary = LEB128.encode(byte_size(no_roots)) <> no_roots

      assert_raise RuntimeError, ~r/missing roots/, fn ->
        CAR.stream_decode([binary]) |> Enum.to_list()
      end
    end

    test "raises on block frame that is too short to contain a CID" do
      {:ok, header_bin} = DRISL.encode(%{"version" => 1, "roots" => []})
      header = LEB128.encode(byte_size(header_bin)) <> header_bin
      # A block frame of 10 bytes is less than the 36-byte CID minimum
      short_block = LEB128.encode(10) <> :binary.copy(<<0>>, 10)

      assert_raise RuntimeError, ~r/too short/, fn ->
        CAR.stream_decode([header <> short_block]) |> Enum.to_list()
      end
    end
  end

  # ---------------------------------------------------------------------------
  # DASL.CAR.DRISL.stream_decode/2
  # ---------------------------------------------------------------------------

  describe "CAR.DRISL.stream_decode/2" do
    test "emits DRISL-decoded terms for each block" do
      term1 = %{"key" => 42}
      term2 = [1, 2, 3]
      {:ok, enc1} = DRISL.encode(term1)
      {:ok, enc2} = DRISL.encode(term2)
      cid1 = CID.compute(enc1, :drisl)
      cid2 = CID.compute(enc2, :drisl)

      car = %DrislCAR{version: 1, roots: [cid1], blocks: %{cid1 => term1, cid2 => term2}}
      {:ok, car_bin} = DrislCAR.encode(car)

      {{1, [root]}, decoded_blocks} =
        DrislCAR.stream_decode([car_bin]) |> collect()

      assert root == cid1
      assert length(decoded_blocks) == 2
      assert Enum.find(decoded_blocks, fn {c, _} -> c == cid1 end) |> elem(1) == term1
      assert Enum.find(decoded_blocks, fn {c, _} -> c == cid2 end) |> elem(1) == term2
    end

    test "header event passes through unchanged" do
      term = %{"x" => 1}
      {:ok, enc} = DRISL.encode(term)
      cid = CID.compute(enc, :drisl)
      car = %DrislCAR{version: 1, roots: [cid], blocks: %{cid => term}}
      {:ok, car_bin} = DrislCAR.encode(car)

      {{version, roots}, _} = DrislCAR.stream_decode([car_bin]) |> collect()

      assert version == 1
      assert roots == [cid]
    end

    test "works with multi-chunk input" do
      term = %{"streamed" => true}
      {:ok, enc} = DRISL.encode(term)
      cid = CID.compute(enc, :drisl)
      car = %DrislCAR{version: 1, roots: [], blocks: %{cid => term}}
      {:ok, car_bin} = DrislCAR.encode(car)

      {{1, []}, [{decoded_cid, decoded_term}]} =
        car_bin |> chunk(8) |> DrislCAR.stream_decode() |> collect()

      assert decoded_cid == cid
      assert decoded_term == term
    end

    test "raises on CID mismatch when verify: true (default)" do
      data = "raw bytes, not drisl"
      cid = CID.compute(data)
      tampered = "tampered raw!!!!!"
      car_bin = build_car_binary([], [{cid, tampered}])

      assert_raise RuntimeError, ~r/CID mismatch/, fn ->
        DrislCAR.stream_decode([car_bin]) |> Enum.to_list()
      end
    end

    test "raises on DRISL decode failure" do
      # A sequence of 0xFF bytes is not valid CBOR and will cause DRISL.decode
      # to return {:error, _}. We use verify: false so the CID mismatch is
      # bypassed and we reach the DRISL decode step.
      raw_data = :binary.copy(<<0xFF>>, 32)
      cid = CID.compute(raw_data, :drisl)
      car_bin = build_car_binary([], [{cid, raw_data}])

      assert_raise RuntimeError, ~r/failed to DRISL-decode/, fn ->
        DrislCAR.stream_decode([car_bin], verify: false) |> Enum.to_list()
      end
    end
  end
end
