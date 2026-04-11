defmodule DASL.DRISL.Encoder do
  @moduledoc """
  DRISL encoder.

  Encodes Elixir terms into DRISL-compliant CBOR binary. See the spec for the
  full set of constraints enforced at encode time.

  Spec: https://dasl.ing/drisl.html
  """

  @doc """
  Encodes an Elixir term into a DRISL-compliant CBOR binary.

  Returns `{:ok, binary}` on success, or `{:error, reason}` on failure.

  ## Examples

      iex> DASL.DRISL.Encoder.encode(%{"a" => 1})
      {:ok, <<0xa1, 0x61, 0x61, 0x01>>}

      iex> DASL.DRISL.Encoder.encode([1, 2, 3])
      {:ok, <<0x83, 0x01, 0x02, 0x03>>}

      iex> DASL.DRISL.Encoder.encode(true)
      {:ok, <<0xf5>>}

      iex> DASL.DRISL.Encoder.encode(nil)
      {:ok, <<0xf6>>}

      iex> {:ok, cid} = DASL.CID.new("bafkreifzjut3te2nhyekklss27nh3k72ysco7y32koao5eei66wof36n5e")
      iex> {:ok, bin} = DASL.DRISL.Encoder.encode(%{"link" => cid})
      iex> is_binary(bin)
      true

      iex> DASL.DRISL.Encoder.encode(%{1 => "bad key"})
      {:error, :non_string_map_key}

  """
  @spec encode(any()) :: {:ok, binary()} | {:error, atom()}
  def encode(term) do
    case encode_value(term) do
      {:ok, iodata} -> {:ok, IO.iodata_to_binary(iodata)}
      {:error, _} = err -> err
    end
  end

  # Returns {:ok, iodata} internally — callers must not assume a flat binary
  # until encode/1 flattens at the boundary.
  @spec encode_value(any()) :: {:ok, iodata()} | {:error, atom()}

  defp encode_value(nil), do: {:ok, <<0xF6>>}
  defp encode_value(false), do: {:ok, <<0xF4>>}
  defp encode_value(true), do: {:ok, <<0xF5>>}

  defp encode_value(i) when is_integer(i) and i >= 0 and i < 0x10000000000000000 do
    {:ok, encode_head(0, i)}
  end

  defp encode_value(i) when is_integer(i) and i < 0 and i >= -0x10000000000000000 do
    {:ok, encode_head(1, -i - 1)}
  end

  defp encode_value(i) when is_integer(i) and i >= 0x10000000000000000 do
    bytes = :binary.encode_unsigned(i)
    {:ok, [encode_head(6, 2), encode_string(2, bytes)]}
  end

  defp encode_value(i) when is_integer(i) do
    bytes = :binary.encode_unsigned(-i - 1)
    {:ok, [encode_head(6, 3), encode_string(2, bytes)]}
  end

  defp encode_value(f) when is_float(f) do
    {:ok, <<0xFB, f::float-64>>}
  end

  defp encode_value(s) when is_binary(s) do
    {:ok, encode_string(3, s)}
  end

  defp encode_value(%CBOR.Tag{tag: :bytes, value: data}) when is_binary(data) do
    {:ok, encode_string(2, data)}
  end

  defp encode_value(%DASL.CID{bytes: cid_bytes}) do
    {:ok, [encode_head(6, 42), encode_string(2, <<0, cid_bytes::binary>>)]}
  end

  defp encode_value(list) when is_list(list) do
    with {:ok, items_iodata} <- encode_list_items(list) do
      {:ok, [encode_head(4, length(list)) | items_iodata]}
    end
  end

  defp encode_value(%{} = map) do
    with :ok <- validate_map_keys(map),
         {:ok, sorted_pairs} <- encode_and_sort_map_pairs(map) do
      {:ok, [encode_head(5, map_size(map)) | sorted_pairs]}
    end
  end

  defp encode_value(_), do: {:error, :unsupported_type}

  @spec encode_list_items(list()) :: {:ok, iodata()} | {:error, atom()}
  defp encode_list_items(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case encode_value(item) do
        {:ok, iodata} -> {:cont, {:ok, [acc | [iodata]]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @spec validate_map_keys(map()) :: :ok | {:error, atom()}
  defp validate_map_keys(map) do
    if Enum.all?(Map.keys(map), &is_binary/1) do
      :ok
    else
      {:error, :non_string_map_key}
    end
  end

  # Encodes all key/value pairs, then sorts by bytewise-lexicographic order
  # of the encoded key — length-first (RFC 7049 §3.9 canonical CBOR sort).
  # Returns a flat iodata list of interleaved [k_bin, v_bin, ...] after sorting.
  @spec encode_and_sort_map_pairs(map()) :: {:ok, iodata()} | {:error, atom()}
  defp encode_and_sort_map_pairs(map) do
    map
    |> Enum.reduce_while({:ok, []}, fn {k, v}, {:ok, acc} ->
      with {:ok, k_bin} <- encode_value(k),
           {:ok, v_iodata} <- encode_value(v) do
        # Flatten k to a binary now so we can sort on it cheaply;
        # v stays as iodata.
        k_flat = IO.iodata_to_binary(k_bin)
        {:cont, {:ok, [{k_flat, v_iodata} | acc]}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, pairs} ->
        sorted =
          pairs
          |> Enum.sort_by(fn {k_flat, _} -> {byte_size(k_flat), k_flat} end)
          |> Enum.flat_map(fn {k_flat, v_iodata} -> [k_flat, v_iodata] end)

        {:ok, sorted}

      err ->
        err
    end
  end

  # Encodes the CBOR initial byte + argument for major type `mt` and value `val`.
  @spec encode_head(0..7, non_neg_integer()) :: binary()
  defp encode_head(mt, val) when val < 24 do
    <<mt::3, val::5>>
  end

  defp encode_head(mt, val) when val < 0x100 do
    <<mt::3, 24::5, val::8>>
  end

  defp encode_head(mt, val) when val < 0x10000 do
    <<mt::3, 25::5, val::16>>
  end

  defp encode_head(mt, val) when val < 0x100000000 do
    <<mt::3, 26::5, val::32>>
  end

  defp encode_head(mt, val) do
    <<mt::3, 27::5, val::64>>
  end

  # Encodes a byte/text string: CBOR head (major type `mt`) + raw bytes.
  @spec encode_string(2 | 3, binary()) :: binary()
  defp encode_string(mt, data) do
    encode_head(mt, byte_size(data)) <> data
  end
end
