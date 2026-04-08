defmodule DASL.DRISL.Decoder do
  @moduledoc """
  DRISL decoder.

  Validates and decodes a CBOR binary according to the DRISL profile. See the
  spec for the full set of constraints.

  Spec: https://dasl.ing/drisl.html
  """

  @doc """
  Decodes a DRISL-encoded binary into an Elixir term.

  CBOR tag 42 values are decoded into `%DASL.CID{}` structs. Returns
  `{:ok, term, rest}` on success, or `{:error, reason}` on failure.

  ## Examples

      iex> DASL.DRISL.Decoder.decode(<<0xa1, 0x61, 0x61, 0x01>>)
      {:ok, %{"a" => 1}, ""}

      iex> DASL.DRISL.Decoder.decode(<<0x83, 0x01, 0x02, 0x03>>)
      {:ok, [1, 2, 3], ""}

      iex> DASL.DRISL.Decoder.decode(<<0xf5>>)
      {:ok, true, ""}

      iex> DASL.DRISL.Decoder.decode(<<0xf6>>)
      {:ok, nil, ""}

  """
  @spec decode(binary()) :: {:ok, any(), binary()} | {:error, atom()}
  def decode(binary) when is_binary(binary) do
    with {:ok, _rest} <- scan_item(binary),
         {:ok, value, rest} <- cbor_decode(binary),
         {:ok, value} <- validate_and_remap(value) do
      {:ok, value, rest}
    end
  end

  # ---------------------------------------------------------------------------
  # Structural scanner
  #
  # Walks the CBOR binary item by item, validating every structural constraint
  # that can be checked at the byte level before handing off to the CBOR
  # library for full decoding. Returns {:ok, remaining_bytes} or an error.
  #
  # Constraints enforced here:
  #   - Half-precision (0xf9) and single-precision (0xfa) floats — forbidden
  #   - CBOR `undefined` (0xf7) — forbidden (only true/false/null allowed)
  #   - All other simple values (0xf8 + any, 0xe0..0xf3) — forbidden
  #   - Minimal integer encoding — value must use the shortest additional bytes
  #   - Minimal byte/text string length encoding
  #   - Minimal array/map count encoding
  #   - Tag 42 must use the short 2-byte form (0xd8 0x2a); all other tags
  #     and all non-minimal tag encodings are forbidden
  #   - Indefinite-length items (additional = 31, break = 0xff) — forbidden
  #   - UTF-8 validity for text strings
  #   - Map keys must be CBOR text strings, in bytewise-lexicographic order,
  #     with no duplicates
  # ---------------------------------------------------------------------------

  @spec scan_item(binary()) :: {:ok, binary()} | {:error, atom()}

  # Empty input: valid (no item to scan)
  defp scan_item(<<>>), do: {:ok, <<>>}

  # --- Major type 7 (floats and simples) ---

  # 0xf9 — half-precision float: forbidden
  defp scan_item(<<0xF9, _::binary>>), do: {:error, :half_precision_float}

  # 0xfa — single-precision float: forbidden
  defp scan_item(<<0xFA, _::binary>>), do: {:error, :single_precision_float}

  # 0xfb — 64-bit float: allowed
  defp scan_item(<<0xFB, _::binary-size(8), rest::binary>>), do: {:ok, rest}

  # 0xf4 false, 0xf5 true, 0xf6 null — allowed simple values
  defp scan_item(<<add, rest::binary>>) when add in [0xF4, 0xF5, 0xF6], do: {:ok, rest}

  # 0xf7 undefined — forbidden
  defp scan_item(<<0xF7, _::binary>>), do: {:error, :forbidden_simple}

  # 0xf8 — one-byte extended simple value: all forbidden in DRISL
  defp scan_item(<<0xF8, _::8, _::binary>>), do: {:error, :forbidden_simple}

  # 0xe0..0xf3 — unassigned simple values (additional 0..19): forbidden
  defp scan_item(<<0b111::3, add::5, _::binary>>) when add < 20,
    do: {:error, :forbidden_simple}

  # --- Major type 0 (unsigned integer) — minimal encoding ---

  # additional < 24: value is the additional bits itself (always minimal)
  defp scan_item(<<0b000::3, add::5, rest::binary>>) when add < 24, do: {:ok, rest}

  # additional = 24: one-byte value; must be >= 24
  defp scan_item(<<0b000_11000, val::8, rest::binary>>) do
    if val >= 24, do: {:ok, rest}, else: {:error, :non_minimal_encoding}
  end

  # additional = 25: two-byte value; must be > 0xFF
  defp scan_item(<<0b000_11001, val::16, rest::binary>>) do
    if val > 0xFF, do: {:ok, rest}, else: {:error, :non_minimal_encoding}
  end

  # additional = 26: four-byte value; must be > 0xFFFF
  defp scan_item(<<0b000_11010, val::32, rest::binary>>) do
    if val > 0xFFFF, do: {:ok, rest}, else: {:error, :non_minimal_encoding}
  end

  # additional = 27: eight-byte value; must be > 0xFFFFFFFF
  defp scan_item(<<0b000_11011, val::64, rest::binary>>) do
    if val > 0xFFFFFFFF, do: {:ok, rest}, else: {:error, :non_minimal_encoding}
  end

  # --- Major type 1 (negative integer) — same minimality rules as type 0 ---

  defp scan_item(<<0b001::3, add::5, rest::binary>>) when add < 24, do: {:ok, rest}

  defp scan_item(<<0b001_11000, val::8, rest::binary>>) do
    if val >= 24, do: {:ok, rest}, else: {:error, :non_minimal_encoding}
  end

  defp scan_item(<<0b001_11001, val::16, rest::binary>>) do
    if val > 0xFF, do: {:ok, rest}, else: {:error, :non_minimal_encoding}
  end

  defp scan_item(<<0b001_11010, val::32, rest::binary>>) do
    if val > 0xFFFF, do: {:ok, rest}, else: {:error, :non_minimal_encoding}
  end

  defp scan_item(<<0b001_11011, val::64, rest::binary>>) do
    if val > 0xFFFFFFFF, do: {:ok, rest}, else: {:error, :non_minimal_encoding}
  end

  # --- Major type 2 (byte string) — minimal length encoding + skip payload ---

  defp scan_item(<<0b010::3, len::5, rest::binary>>) when len < 24,
    do: skip_bytes(len, rest)

  defp scan_item(<<0b010_11000, len::8, rest::binary>>) do
    if len >= 24, do: skip_bytes(len, rest), else: {:error, :non_minimal_encoding}
  end

  defp scan_item(<<0b010_11001, len::16, rest::binary>>) do
    if len > 0xFF, do: skip_bytes(len, rest), else: {:error, :non_minimal_encoding}
  end

  defp scan_item(<<0b010_11010, len::32, rest::binary>>) do
    if len > 0xFFFF, do: skip_bytes(len, rest), else: {:error, :non_minimal_encoding}
  end

  defp scan_item(<<0b010_11011, len::64, rest::binary>>) do
    if len > 0xFFFFFFFF, do: skip_bytes(len, rest), else: {:error, :non_minimal_encoding}
  end

  # --- Major type 3 (text string) — minimal length encoding + UTF-8 check ---

  defp scan_item(<<0b011::3, len::5, rest::binary>>) when len < 24,
    do: skip_text(len, rest)

  defp scan_item(<<0b011_11000, len::8, rest::binary>>) do
    if len >= 24, do: skip_text(len, rest), else: {:error, :non_minimal_encoding}
  end

  defp scan_item(<<0b011_11001, len::16, rest::binary>>) do
    if len > 0xFF, do: skip_text(len, rest), else: {:error, :non_minimal_encoding}
  end

  defp scan_item(<<0b011_11010, len::32, rest::binary>>) do
    if len > 0xFFFF, do: skip_text(len, rest), else: {:error, :non_minimal_encoding}
  end

  defp scan_item(<<0b011_11011, len::64, rest::binary>>) do
    if len > 0xFFFFFFFF, do: skip_text(len, rest), else: {:error, :non_minimal_encoding}
  end

  # --- Major type 4 (array) — minimal count encoding, then scan sub-items ---

  defp scan_item(<<0b100::3, count::5, rest::binary>>) when count < 24,
    do: scan_items(count, rest)

  defp scan_item(<<0b100_11000, count::8, rest::binary>>) do
    if count >= 24, do: scan_items(count, rest), else: {:error, :non_minimal_encoding}
  end

  defp scan_item(<<0b100_11001, count::16, rest::binary>>) do
    if count > 0xFF, do: scan_items(count, rest), else: {:error, :non_minimal_encoding}
  end

  defp scan_item(<<0b100_11010, count::32, rest::binary>>) do
    if count > 0xFFFF, do: scan_items(count, rest), else: {:error, :non_minimal_encoding}
  end

  defp scan_item(<<0b100_11011, count::64, rest::binary>>) do
    if count > 0xFFFFFFFF, do: scan_items(count, rest), else: {:error, :non_minimal_encoding}
  end

  # --- Major type 5 (map) — minimal count encoding, ordered string keys ---

  defp scan_item(<<0b101::3, count::5, rest::binary>>) when count < 24,
    do: scan_map_pairs(count, rest, nil)

  defp scan_item(<<0b101_11000, count::8, rest::binary>>) do
    if count >= 24,
      do: scan_map_pairs(count, rest, nil),
      else: {:error, :non_minimal_encoding}
  end

  defp scan_item(<<0b101_11001, count::16, rest::binary>>) do
    if count > 0xFF,
      do: scan_map_pairs(count, rest, nil),
      else: {:error, :non_minimal_encoding}
  end

  defp scan_item(<<0b101_11010, count::32, rest::binary>>) do
    if count > 0xFFFF,
      do: scan_map_pairs(count, rest, nil),
      else: {:error, :non_minimal_encoding}
  end

  defp scan_item(<<0b101_11011, count::64, rest::binary>>) do
    if count > 0xFFFFFFFF,
      do: scan_map_pairs(count, rest, nil),
      else: {:error, :non_minimal_encoding}
  end

  # --- Major type 6 (tag) ---

  # Tag 2 (unsigned bignum) and tag 3 (negative bignum) in short 1-byte form:
  # allowed by DRISL/c42 only for integers outside [-2^64, 2^64-1]. The
  # tagged value must be a bytestring with no leading zero bytes and a value
  # that does not fit in a CBOR major type 0/1 integer.
  defp scan_item(<<0b110_00010, rest::binary>>), do: scan_bignum(rest)
  defp scan_item(<<0b110_00011, rest::binary>>), do: scan_bignum(rest)

  # Tag 42 in short 2-byte form (0xd8 0x2a) is the only CID tag form permitted.
  defp scan_item(<<0xD8, 0x2A, rest::binary>>), do: scan_item(rest)

  # Any other tag (including non-minimal encodings of tag 42, tag 2, tag 3,
  # or any other tag number) is forbidden.
  defp scan_item(<<0b110::3, _::5, _::binary>>), do: {:error, :forbidden_tag}

  # --- Catch-all: invalid / indefinite / reserved ---

  defp scan_item(_), do: {:error, :cbor_decode_error}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Validates that the next item in `bin` is a bytestring representing a bignum
  # value that requires tag 2/3 — i.e. > 0xFFFFFFFFFFFFFFFF (2^64 - 1).
  # Leading zero bytes are forbidden (non-minimal). Returns {:ok, rest}.
  @uint64_max 0xFFFFFFFFFFFFFFFF

  @spec scan_bignum(binary()) :: {:ok, binary()} | {:error, atom()}

  defp scan_bignum(<<0b010::3, len::5, rest::binary>>) when len < 24 and len > 0 do
    case rest do
      <<0x00, _::binary>> ->
        {:error, :non_minimal_encoding}

      <<bytes::binary-size(len), tail::binary>> ->
        if :binary.decode_unsigned(bytes) > @uint64_max,
          do: {:ok, tail},
          else: {:error, :non_minimal_encoding}

      _ ->
        {:error, :cbor_decode_error}
    end
  end

  defp scan_bignum(_), do: {:error, :non_minimal_encoding}

  @spec skip_bytes(non_neg_integer(), binary()) :: {:ok, binary()} | {:error, atom()}
  defp skip_bytes(len, rest) do
    case rest do
      <<_::binary-size(len), tail::binary>> -> {:ok, tail}
      _ -> {:error, :cbor_decode_error}
    end
  end

  @spec skip_text(non_neg_integer(), binary()) :: {:ok, binary()} | {:error, atom()}
  defp skip_text(len, rest) do
    case rest do
      <<text::binary-size(len), tail::binary>> ->
        if String.valid?(text),
          do: {:ok, tail},
          else: {:error, :invalid_utf8}

      _ ->
        {:error, :cbor_decode_error}
    end
  end

  @spec scan_items(non_neg_integer(), binary()) :: {:ok, binary()} | {:error, atom()}
  defp scan_items(0, rest), do: {:ok, rest}

  defp scan_items(n, bin) do
    case scan_item(bin) do
      {:ok, rest} -> scan_items(n - 1, rest)
      {:error, _} = err -> err
    end
  end

  # Scans `count` map key/value pairs. Keys must be CBOR text strings and must
  # be in strictly increasing bytewise-lexicographic order of their encoded
  # form (length-first, then content). `prev_key_enc` is the encoded bytes of
  # the previous key for ordering comparison; nil on the first pair.
  @spec scan_map_pairs(non_neg_integer(), binary(), binary() | nil) ::
          {:ok, binary()} | {:error, atom()}
  defp scan_map_pairs(0, rest, _prev), do: {:ok, rest}

  defp scan_map_pairs(n, bin, prev_key_enc) do
    with {:ok, key_enc, after_key} <- extract_text_key(bin),
         :ok <- check_key_order(key_enc, prev_key_enc),
         {:ok, after_value} <- scan_item(after_key) do
      scan_map_pairs(n - 1, after_value, key_enc)
    end
  end

  # Extracts one CBOR text string key from the binary, returning its full
  # encoded bytes (including the initial byte) and the remaining binary.
  # Rejects non-text-string keys and non-minimal length encodings.
  @spec extract_text_key(binary()) :: {:ok, binary(), binary()} | {:error, atom()}

  defp extract_text_key(<<0b011::3, len::5, rest::binary>>) when len < 24 do
    head = <<0b011::3, len::5>>

    case rest do
      <<text::binary-size(len), tail::binary>> ->
        if String.valid?(text),
          do: {:ok, head <> text, tail},
          else: {:error, :invalid_utf8}

      _ ->
        {:error, :cbor_decode_error}
    end
  end

  defp extract_text_key(<<0b011_11000, len::8, rest::binary>>) when len >= 24,
    do: extract_text_key_payload(<<0b011_11000, len::8>>, len, rest)

  defp extract_text_key(<<0b011_11000, _::8, _::binary>>),
    do: {:error, :non_minimal_encoding}

  defp extract_text_key(<<0b011_11001, len::16, rest::binary>>) when len > 0xFF,
    do: extract_text_key_payload(<<0b011_11001, len::16>>, len, rest)

  defp extract_text_key(<<0b011_11001, _::16, _::binary>>),
    do: {:error, :non_minimal_encoding}

  # Any other initial byte is not a text string key
  defp extract_text_key(_), do: {:error, :non_string_map_key}

  @spec extract_text_key_payload(binary(), non_neg_integer(), binary()) ::
          {:ok, binary(), binary()} | {:error, atom()}
  defp extract_text_key_payload(head, len, rest) do
    case rest do
      <<text::binary-size(len), tail::binary>> ->
        if String.valid?(text),
          do: {:ok, head <> text, tail},
          else: {:error, :invalid_utf8}

      _ ->
        {:error, :cbor_decode_error}
    end
  end

  @spec check_key_order(binary(), binary() | nil) :: :ok | {:error, atom()}
  defp check_key_order(_key_enc, nil), do: :ok

  defp check_key_order(key_enc, prev_enc) do
    # Bytewise-lexicographic ordering by encoded form: first by length, then
    # by content. Since CBOR minimal encoding encodes length in the head bytes,
    # comparing the full encoded binary is equivalent to length-first ordering.
    if byte_size(key_enc) > byte_size(prev_enc) or
         (byte_size(key_enc) == byte_size(prev_enc) and key_enc > prev_enc),
       do: :ok,
       else: {:error, :map_key_order}
  end

  # ---------------------------------------------------------------------------
  # CBOR library decode pass
  # ---------------------------------------------------------------------------

  @spec cbor_decode(binary()) :: {:ok, any(), binary()} | {:error, atom()}
  defp cbor_decode(binary) do
    case CBOR.decode(binary) do
      {:ok, value, rest} -> {:ok, value, rest}
      {:error, _} -> {:error, :cbor_decode_error}
    end
  end

  # ---------------------------------------------------------------------------
  # Post-decode validation and remapping
  #
  # The CBOR library auto-decodes certain tags to Elixir structs (tag 0 →
  # DateTime/Date/Time, tag 32 → URI). These are forbidden in DRISL.
  # Tag 42 → CID struct. Tag 2/3 (bignum) → Elixir integer if in range,
  # or left as %CBOR.Tag{tag: 2|3} for very large values; both are allowed
  # in DRISL/c42 as long as they are minimally encoded (enforced above in
  # the structural scanner: bignum tag is still tag 42 short-form only).
  # ---------------------------------------------------------------------------

  @spec validate_and_remap(any()) :: {:ok, any()} | {:error, atom()}

  defp validate_and_remap(%CBOR.Tag{tag: 42} = tag) do
    case DASL.CID.from_cbor(tag) do
      {:ok, cid} -> {:ok, cid}
      {:error, _} -> {:error, :invalid_cid}
    end
  end

  defp validate_and_remap(%CBOR.Tag{tag: :bytes} = tag), do: {:ok, tag}

  defp validate_and_remap(%CBOR.Tag{tag: :simple}),
    do: {:error, :forbidden_simple}

  defp validate_and_remap(%CBOR.Tag{tag: :float}),
    do: {:error, :forbidden_float}

  defp validate_and_remap(%CBOR.Tag{}),
    do: {:error, :forbidden_tag}

  # The CBOR library decodes tag 0 directly to DateTime/Date/Time and
  # tag 32 to URI. Reject all of them as DRISL forbids these tags.
  defp validate_and_remap(%DateTime{}), do: {:error, :forbidden_tag}
  defp validate_and_remap(%Date{}), do: {:error, :forbidden_tag}
  defp validate_and_remap(%Time{}), do: {:error, :forbidden_tag}
  defp validate_and_remap(%URI{}), do: {:error, :forbidden_tag}

  defp validate_and_remap(%{} = map) do
    map
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with :ok <- validate_map_key(key),
           {:ok, remapped} <- validate_and_remap(value) do
        {:cont, {:ok, Map.put(acc, key, remapped)}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp validate_and_remap(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case validate_and_remap(item) do
        {:ok, remapped} -> {:cont, {:ok, [remapped | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      err -> err
    end
  end

  defp validate_and_remap(scalar), do: {:ok, scalar}

  @spec validate_map_key(any()) :: :ok | {:error, atom()}
  defp validate_map_key(key) when is_binary(key), do: :ok
  defp validate_map_key(_), do: {:error, :non_string_map_key}
end
