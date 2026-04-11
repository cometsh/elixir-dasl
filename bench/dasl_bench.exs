##
## DASL Benchmark
##
## Benchmarks DRISL encode/decode and CAR decode (both in-memory and streaming)
## against the sample CAR files in ./tmp.
##
## Run with:
##   mix run bench/dasl_bench.exs
##
## Options (env vars):
##   BENCH_TIME     - seconds per benchmark job (default: 5)
##   BENCH_WARMUP   - warmup seconds (default: 2)
##   BENCH_MEMORY   - memory measurement seconds (default: 1)
##

alias DASL.{CAR, DRISL}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

defmodule Bench.Helpers do
  @doc """
  Reads a CAR file and extracts the first DRISL-encoded block's raw bytes,
  plus the entire file binary for full-load benchmarks.
  """
  def load_car!(path) do
    binary = File.read!(path)
    size_kb = Float.round(byte_size(binary) / 1024, 1)
    IO.puts("  Loaded #{Path.basename(path)} (#{size_kb} KB)")
    binary
  end

  @doc """
  Decodes a CAR binary and returns `{car, block_raw, block_term}`:

  - `block_raw`  — raw DRISL binary of the first block (input for decode bench)
  - `block_term` — decoded Elixir term of the first block (input for encode bench)
  """
  def decode_car!(binary) do
    {:ok, car} = CAR.decode(binary, verify: false)
    block_raw = car.blocks |> Map.values() |> List.first()
    {:ok, block_term, _} = DRISL.decode(block_raw)
    {car, block_raw, block_term}
  end

  @doc """
  Returns a label with the file size tier for Benchee job names.
  """
  def label(path) do
    bytes = File.stat!(path).size

    tier =
      cond do
        bytes < 50_000 -> "small"
        bytes < 500_000 -> "medium"
        true -> "large"
      end

    "#{Path.basename(path)} (#{tier})"
  end
end

# ---------------------------------------------------------------------------
# Load fixtures
# ---------------------------------------------------------------------------

IO.puts("\nLoading CAR fixtures...")

car_files =
  ~w[tmp/alt.car tmp/comet.car tmp/ovyerus.car]
  |> Enum.filter(&File.exists?/1)

if car_files == [] do
  IO.puts("No CAR files found in ./tmp — aborting.")
  System.halt(1)
end

fixtures =
  Enum.map(car_files, fn path ->
    binary = Bench.Helpers.load_car!(path)
    {car, block_raw, block_term} = Bench.Helpers.decode_car!(binary)
    label = Bench.Helpers.label(path)
    {label, path, binary, car, block_raw, block_term}
  end)

IO.puts("")

# ---------------------------------------------------------------------------
# Benchee configuration
# ---------------------------------------------------------------------------

bench_time = String.to_integer(System.get_env("BENCH_TIME", "5"))
bench_warmup = String.to_integer(System.get_env("BENCH_WARMUP", "2"))
bench_memory = String.to_integer(System.get_env("BENCH_MEMORY", "1"))

shared_opts = [
  time: bench_time,
  warmup: bench_warmup,
  memory_time: bench_memory,
  print: [fast_warning: false]
]

# ---------------------------------------------------------------------------
# 1. DRISL encode + decode — one benchmark per file's first block
# ---------------------------------------------------------------------------

IO.puts("=" |> String.duplicate(72))
IO.puts("DRISL encode / decode (per-block)")
IO.puts("=" |> String.duplicate(72))

drisl_jobs =
  Enum.flat_map(fixtures, fn {label, _path, _binary, _car, block_raw, block_term} ->
    [
      {"encode #{label}", fn -> DRISL.encode(block_term) end},
      {"decode #{label}", fn -> DRISL.decode(block_raw) end}
    ]
  end)
  |> Map.new()

Benchee.run(drisl_jobs, shared_opts)

# ---------------------------------------------------------------------------
# 2. CAR decode (in-memory) — full file load into a CAR struct
# ---------------------------------------------------------------------------

IO.puts("=" |> String.duplicate(72))
IO.puts("CAR.decode/2 (in-memory, verify: true)")
IO.puts("=" |> String.duplicate(72))

car_decode_jobs =
  Enum.map(fixtures, fn {label, _path, binary, _car, _block_raw, _block_term} ->
    {"decode #{label}", fn -> CAR.decode(binary) end}
  end)
  |> Map.new()

Benchee.run(car_decode_jobs, shared_opts)

# ---------------------------------------------------------------------------
# 3. CAR.decode/2 without CID verification — isolates parsing overhead
# ---------------------------------------------------------------------------

IO.puts("=" |> String.duplicate(72))
IO.puts("CAR.decode/2 (in-memory, verify: false)")
IO.puts("=" |> String.duplicate(72))

car_decode_noverify_jobs =
  Enum.map(fixtures, fn {label, _path, binary, _car, _block_raw, _block_term} ->
    {"decode (no verify) #{label}", fn -> CAR.decode(binary, verify: false) end}
  end)
  |> Map.new()

Benchee.run(car_decode_noverify_jobs, shared_opts)

# ---------------------------------------------------------------------------
# 4. CAR.stream_decode/2 — streaming via File.stream!
##   Skipped for the 39 MB file at default settings to keep total run time
##   reasonable; enable by setting BENCH_STREAM_LARGE=1.
# ---------------------------------------------------------------------------

IO.puts("=" |> String.duplicate(72))
IO.puts("CAR.stream_decode/2 (File.stream!, 64 KB chunks)")
IO.puts("=" |> String.duplicate(72))

stream_large? = System.get_env("BENCH_STREAM_LARGE", "0") == "1"
chunk_size = 65_536

stream_jobs =
  fixtures
  |> Enum.reject(fn {label, _path, binary, _car, _block_raw, _block_term} ->
    large? = byte_size(binary) > 10_000_000
    skip = large? and not stream_large?
    if skip, do: IO.puts("  Skipping #{label} (set BENCH_STREAM_LARGE=1 to include)")
    skip
  end)
  |> Enum.map(fn {label, path, _binary, _car, _block_raw, _block_term} ->
    {
      "stream #{label}",
      fn ->
        File.stream!(path, chunk_size)
        |> CAR.stream_decode()
        |> Stream.run()
      end
    }
  end)
  |> Map.new()

if map_size(stream_jobs) > 0, do: Benchee.run(stream_jobs, shared_opts)

IO.puts("\nDone.")
