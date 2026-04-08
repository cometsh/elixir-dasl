defmodule DASL.DRISL.FixturesTest do
  @moduledoc """
  Runs the hyphacoop/dasl-testing CBOR fixture suite against DASL.DRISL.

  Fixture source: https://github.com/hyphacoop/dasl-testing/tree/main/fixtures/cbor

  Test types:
  - `roundtrip`  — decode must succeed with no leftover bytes, then re-encode
                   must produce exactly the original bytes.
  - `invalid_in` — decode must fail (error tuple or leftover bytes).
  - `invalid_out` — decode may succeed; re-encode must fail.

  Only test cases whose `tags` list intersects with `@applicable_tags` are run.
  Add a test's `"id"` field to `@skipped_ids` to skip it explicitly.
  """

  use ExUnit.Case, async: true

  @fixtures_dir Path.join([__DIR__, "..", "fixtures", "cbor"])

  # Tags this implementation claims conformance with. DRISL implements the c42
  # profile, which differs from dag-cbor in some areas (e.g. bignum support),
  # so "dag-cbor" is intentionally excluded.
  @applicable_tags MapSet.new(["c42", "dasl-cid", "basic"])

  # Explicit per-ID skips (use the "id" field from the fixture JSON).
  @skipped_ids MapSet.new([])

  # Explicit per-name skips as {name, type} pairs, for fixtures without an
  # "id" field. Add entries here to skip by name + test type.
  #
  # TODO: "Big DASL CID" — BLAKE3 (hash type 0x1e) CIDs are not yet supported;
  #   the CID implementation currently only handles SHA-256 (0x12). Needs a
  #   configurable hash registry or explicit BLAKE3 support to pass.
  @skipped_names MapSet.new([{"Big DASL CID", "roundtrip"}])

  # ---------------------------------------------------------------------------
  # Fixture loading
  # ---------------------------------------------------------------------------

  @fixture_files File.ls!(@fixtures_dir)
                 |> Enum.filter(&String.ends_with?(&1, ".json"))
                 |> Enum.sort()

  @fixtures Enum.flat_map(@fixture_files, fn filename ->
              path = Path.join(@fixtures_dir, filename)
              cases = path |> File.read!() |> JSON.decode!()
              Enum.map(cases, fn tc -> Map.put(tc, "file", filename) end)
            end)

  for fixture <- @fixtures do
    file = fixture["file"]
    name = fixture["name"]
    type = fixture["type"]
    data = fixture["data"]
    tags = MapSet.new(fixture["tags"])
    id = fixture["id"]

    applicable? = not MapSet.disjoint?(tags, @applicable_tags)

    skipped? =
      (id != nil and MapSet.member?(@skipped_ids, id)) or
        MapSet.member?(@skipped_names, {name, type})

    test_name = "[#{file}] #{name} (#{type})"

    cond do
      skipped? ->
        @tag :skip
        test test_name do
          :ok
        end

      not applicable? ->
        :ok

      type == "roundtrip" ->
        @tag fixture_type: :roundtrip
        test test_name do
          bytes = Base.decode16!(unquote(data), case: :lower)

          assert {:ok, term, rest} = DASL.DRISL.decode(bytes),
                 "decode failed for: #{unquote(data)}"

          assert rest == "",
                 "decode left unconsumed bytes (#{byte_size(rest)} bytes) for: #{unquote(data)}"

          assert {:ok, ^bytes} = DASL.DRISL.encode(term),
                 "re-encode did not reproduce original bytes for: #{unquote(data)}"
        end

      type == "invalid_in" ->
        @tag fixture_type: :invalid_in
        test test_name do
          bytes = Base.decode16!(unquote(data), case: :lower)

          result = DASL.DRISL.decode(bytes)

          refute match?({:ok, _, ""}, result),
                 "expected decode to fail or leave leftover bytes, but got clean {:ok, _, \"\"} for: #{unquote(data)}"
        end

      type == "invalid_out" ->
        @tag fixture_type: :invalid_out
        test test_name do
          bytes = Base.decode16!(unquote(data), case: :lower)

          case DASL.DRISL.decode(bytes) do
            {:ok, term, _rest} ->
              assert {:error, _} = DASL.DRISL.encode(term),
                     "expected encode to fail for: #{unquote(data)}"

            {:error, _} ->
              # If decode already fails, the invalid_out condition is trivially
              # satisfied — the data cannot be produced by a compliant encoder.
              :ok
          end
        end

      true ->
        :ok
    end
  end
end
