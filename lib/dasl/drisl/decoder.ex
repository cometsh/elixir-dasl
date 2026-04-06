defmodule DASL.DRISL.Decoder do
  @moduledoc """
  DRISL decoder.

  Validates and decodes a CBOR binary according to the DRISL profile:

  - Only tag 42 (CIDs) is permitted; all other CBOR tags are rejected.
  - Map keys must be strings.
  - Simple values other than `true`, `false`, and `null` are rejected.
  - Non-finite floats (infinity, negative infinity, NaN) are rejected.
  - Half-precision (major 7, additional 25) and single-precision (major 7, additional 26)
    float encodings are rejected; only 64-bit IEEE 754 is allowed.
  - Indefinite-length items are rejected (enforced by the CBOR library).

  Spec: https://dasl.ing/drisl.html
  """

  @doc """
  Decodes a DRISL-encoded binary into an Elixir term.

  CIDs encoded as CBOR tag 42 are decoded into `%DASL.CID{}` structs.

  Returns `{:ok, term, rest}` on success, or `{:error, reason}` on failure.
  `reason` is one of:
    - `:half_precision_float` — half-precision float encoding found
    - `:single_precision_float` — single-precision float encoding found
    - `:cbor_decode_error` — CBOR is structurally invalid
    - `:forbidden_tag` — a CBOR tag other than 42 was used
    - `:non_string_map_key` — a map key is not a string
    - `:forbidden_simple` — a simple value other than true/false/null
    - `:forbidden_float` — a non-finite float (inf, -inf, NaN)
    - `:invalid_cid` — tag-42 value does not contain a valid CID

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
    with :ok <- scan_float_precision(binary),
         {:ok, value, rest} <- cbor_decode(binary),
         {:ok, value} <- validate_and_remap(value) do
      {:ok, value, rest}
    end
  end

  # Structurally scans the CBOR binary, following CBOR item boundaries so that
  # payload bytes inside bytestrings and text strings are never mistaken for
  # CBOR initial bytes. Rejects half-precision (0xf9) and single-precision
  # (0xfa) float initial bytes wherever they appear as CBOR items.
  @spec scan_float_precision(binary()) :: :ok | {:error, atom()}
  defp scan_float_precision(binary) do
    case scan_item(binary) do
      {:ok, _rest} -> :ok
      {:error, _} = err -> err
    end
  end

  # Scans one CBOR item from `bin`, returns `{:ok, remaining}` or an error.
  @spec scan_item(binary()) :: {:ok, binary()} | {:error, atom()}
  defp scan_item(<<>>), do: {:ok, <<>>}

  # Major type 7, additional 25 = half-precision float — forbidden
  defp scan_item(<<0b111_11001, _::binary>>),
    do: {:error, :half_precision_float}

  # Major type 7, additional 26 = single-precision float — forbidden
  defp scan_item(<<0b111_11010, _::binary>>),
    do: {:error, :single_precision_float}

  # Major type 7, additional 27 = 64-bit float — allowed, advance 8 bytes
  defp scan_item(<<0b111_11011, _::binary-size(8), rest::binary>>),
    do: {:ok, rest}

  # Major type 7, additional < 24 = simple value or float16/32 handled above
  # true (0xf5), false (0xf4), null (0xf6), undefined (0xf7) are 1-byte items
  defp scan_item(<<0b111::3, add::5, rest::binary>>) when add < 24,
    do: {:ok, rest}

  # Major type 7, additional 24 = one-byte simple value
  defp scan_item(<<0b111_11000, _::8, rest::binary>>),
    do: {:ok, rest}

  # Major type 0 (uint) or 1 (nint): value encoded in additional bytes
  defp scan_item(<<mt::3, add::5, rest::binary>>) when mt in [0, 1] and add < 24,
    do: {:ok, rest}

  defp scan_item(<<mt::3, 24::5, _::8, rest::binary>>) when mt in [0, 1],
    do: {:ok, rest}

  defp scan_item(<<mt::3, 25::5, _::16, rest::binary>>) when mt in [0, 1],
    do: {:ok, rest}

  defp scan_item(<<mt::3, 26::5, _::32, rest::binary>>) when mt in [0, 1],
    do: {:ok, rest}

  defp scan_item(<<mt::3, 27::5, _::64, rest::binary>>) when mt in [0, 1],
    do: {:ok, rest}

  # Major type 2 (bytestring) or 3 (text string): skip payload bytes
  defp scan_item(<<mt::3, len::5, rest::binary>>) when mt in [2, 3] and len < 24 do
    case rest do
      <<_::binary-size(len), tail::binary>> -> {:ok, tail}
      _ -> {:error, :cbor_decode_error}
    end
  end

  defp scan_item(<<mt::3, 24::5, len::8, rest::binary>>) when mt in [2, 3] do
    case rest do
      <<_::binary-size(len), tail::binary>> -> {:ok, tail}
      _ -> {:error, :cbor_decode_error}
    end
  end

  defp scan_item(<<mt::3, 25::5, len::16, rest::binary>>) when mt in [2, 3] do
    case rest do
      <<_::binary-size(len), tail::binary>> -> {:ok, tail}
      _ -> {:error, :cbor_decode_error}
    end
  end

  defp scan_item(<<mt::3, 26::5, len::32, rest::binary>>) when mt in [2, 3] do
    case rest do
      <<_::binary-size(len), tail::binary>> -> {:ok, tail}
      _ -> {:error, :cbor_decode_error}
    end
  end

  defp scan_item(<<mt::3, 27::5, len::64, rest::binary>>) when mt in [2, 3] do
    case rest do
      <<_::binary-size(len), tail::binary>> -> {:ok, tail}
      _ -> {:error, :cbor_decode_error}
    end
  end

  # Major type 4 (array): scan `count` sub-items
  defp scan_item(<<0b100::3, count::5, rest::binary>>) when count < 24,
    do: scan_items(count, rest)

  defp scan_item(<<0b100_11000, count::8, rest::binary>>),
    do: scan_items(count, rest)

  defp scan_item(<<0b100_11001, count::16, rest::binary>>),
    do: scan_items(count, rest)

  defp scan_item(<<0b100_11010, count::32, rest::binary>>),
    do: scan_items(count, rest)

  defp scan_item(<<0b100_11011, count::64, rest::binary>>),
    do: scan_items(count, rest)

  # Major type 5 (map): scan `count * 2` sub-items (key + value pairs)
  defp scan_item(<<0b101::3, count::5, rest::binary>>) when count < 24,
    do: scan_items(count * 2, rest)

  defp scan_item(<<0b101_11000, count::8, rest::binary>>),
    do: scan_items(count * 2, rest)

  defp scan_item(<<0b101_11001, count::16, rest::binary>>),
    do: scan_items(count * 2, rest)

  defp scan_item(<<0b101_11010, count::32, rest::binary>>),
    do: scan_items(count * 2, rest)

  defp scan_item(<<0b101_11011, count::64, rest::binary>>),
    do: scan_items(count * 2, rest)

  # Major type 6 (tag): scan the tag number header then one sub-item
  defp scan_item(<<0b110::3, _tag::5, rest::binary>>),
    do: scan_item(rest)

  defp scan_item(<<0b110_11000, _::8, rest::binary>>),
    do: scan_item(rest)

  defp scan_item(<<0b110_11001, _::16, rest::binary>>),
    do: scan_item(rest)

  defp scan_item(<<0b110_11010, _::32, rest::binary>>),
    do: scan_item(rest)

  defp scan_item(<<0b110_11011, _::64, rest::binary>>),
    do: scan_item(rest)

  defp scan_item(_), do: {:error, :cbor_decode_error}

  @spec scan_items(non_neg_integer(), binary()) :: {:ok, binary()} | {:error, atom()}
  defp scan_items(0, rest), do: {:ok, rest}

  defp scan_items(n, bin) do
    case scan_item(bin) do
      {:ok, rest} -> scan_items(n - 1, rest)
      {:error, _} = err -> err
    end
  end

  @spec cbor_decode(binary()) :: {:ok, any(), binary()} | {:error, atom()}
  defp cbor_decode(binary) do
    case CBOR.decode(binary) do
      {:ok, value, rest} -> {:ok, value, rest}
      {:error, _} -> {:error, :cbor_decode_error}
    end
  end

  # Recursively validate and remap a decoded CBOR value.
  # The CBOR library auto-decodes certain tags to Elixir structs (tag 0 →
  # DateTime/Date/Time, tag 32 → URI). These are forbidden in DRISL.
  @spec validate_and_remap(any()) :: {:ok, any()} | {:error, atom()}
  defp validate_and_remap(%CBOR.Tag{tag: 42} = tag) do
    case DASL.CID.from_cbor(tag) do
      {:ok, cid} -> {:ok, cid}
      {:error, _} -> {:error, :invalid_cid}
    end
  end

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
