defmodule DASL.CAR.StreamDecoder do
  @moduledoc """
  Streaming decoder for DASL CAR binaries.

  Transforms an enumerable of binary chunks (e.g. from `File.stream!/3` or an
  HTTP response body) into a stream of decoded items without loading the entire
  file into memory.

  Emits the following elements in order:

    * `{:header, version, roots}` — exactly once, as soon as the header frame
      has been fully received
    * `{:block, cid, data}` — once per block; `data` is the raw binary

  Raises on any parse error (truncated stream, invalid header, CID mismatch,
  etc.).
  """

  alias DASL.{CID, DRISL}
  alias Varint.LEB128

  @cid_byte_size 36

  @type header_item :: {:header, pos_integer(), [CID.t()]}
  @type block_item :: {:block, CID.t(), binary()}
  @type stream_item :: header_item() | block_item()

  @doc """
  Transforms a stream of binary chunks into a stream of decoded CAR items.

  The input enumerable must yield binaries of any size. Items are emitted as
  soon as a complete frame has been buffered.

  ## Options

    * `:verify` — boolean, default `true`. Verifies each block's raw data
      against its CID digest using `DASL.CID.verify?/2`. Raises on mismatch.

  ## Examples

      File.stream!("large.car", [], 65_536)
      |> DASL.CAR.StreamDecoder.decode_stream()
      |> Enum.each(fn
        {:header, _version, roots} -> IO.inspect(roots, label: "roots")
        {:block, cid, _data}       -> IO.inspect(cid, label: "block")
      end)

  """
  @spec decode_stream(Enumerable.t(), keyword()) :: Enumerable.t()
  def decode_stream(chunk_stream, opts \\ []) do
    verify = Keyword.get(opts, :verify, true)
    initial = {:await_header, <<>>, verify}

    Stream.transform(
      chunk_stream,
      fn -> initial end,
      fn chunk, state -> step(state, chunk) end,
      fn state -> finish(state) end
    )
  end

  # ---------------------------------------------------------------------------
  # Stream.transform reducer — called once per incoming chunk
  # ---------------------------------------------------------------------------

  @spec step({atom(), binary(), boolean()}, binary()) ::
          {[stream_item()], {atom(), binary(), boolean()}}
  defp step({phase, buffer, verify}, chunk) do
    drain(phase, buffer <> chunk, verify, [])
  end

  # ---------------------------------------------------------------------------
  # Buffer drain loop — extracts as many complete frames as possible
  # ---------------------------------------------------------------------------

  # Header phase: attempt to read a framed DRISL header
  @spec drain(atom(), binary(), boolean(), [stream_item()]) ::
          {[stream_item()], {atom(), binary(), boolean()}}
  defp drain(:await_header, buffer, verify, acc) do
    case try_read_frame(buffer) do
      :need_more ->
        {Enum.reverse(acc), {:await_header, buffer, verify}}

      {:ok, header_bin, rest} ->
        {version, roots} = parse_header!(header_bin)
        item = {:header, version, roots}
        drain(:await_blocks, rest, verify, [item | acc])
    end
  end

  # Block phase: attempt to read framed blocks until buffer is exhausted
  defp drain(:await_blocks, <<>>, verify, acc) do
    {Enum.reverse(acc), {:await_blocks, <<>>, verify}}
  end

  defp drain(:await_blocks, buffer, verify, acc) do
    case try_read_frame(buffer) do
      :need_more ->
        {Enum.reverse(acc), {:await_blocks, buffer, verify}}

      {:ok, frame, rest} ->
        {cid, data} = parse_block!(frame, verify)
        item = {:block, cid, data}
        drain(:await_blocks, rest, verify, [item | acc])
    end
  end

  # ---------------------------------------------------------------------------
  # Stream.transform after — called when the upstream enum is exhausted
  # ---------------------------------------------------------------------------

  @spec finish({atom(), binary(), boolean()}) :: :ok
  defp finish({_phase, <<>>, _verify}), do: :ok

  defp finish({phase, leftover, _verify}) do
    # TODO: when loading my repo with `File.stream!()` without any byte chunking, this fails here.
    # But specifying any bytes makes it work. Is there something seen in it that looks like newline which gets consumed?
    IO.inspect(leftover, label: "leftovers")
    raise "CAR stream ended with #{byte_size(leftover)} unprocessed bytes in phase #{phase}"
  end

  # ---------------------------------------------------------------------------
  # Frame reading — LEB128 length-prefix + body
  # ---------------------------------------------------------------------------

  # Returns {:ok, frame_binary, rest} or :need_more.
  # A "frame" is the raw bytes declared by the LEB128 length prefix — it does
  # NOT include the length prefix itself.
  @spec try_read_frame(binary()) :: {:ok, binary(), binary()} | :need_more
  defp try_read_frame(buffer) do
    case decode_varint(buffer) do
      :need_more ->
        :need_more

      {length, rest} ->
        if byte_size(rest) >= length do
          <<frame::binary-size(length), remaining::binary>> = rest
          {:ok, frame, remaining}
        else
          :need_more
        end
    end
  end

  # Wraps LEB128.decode/1 — raises ArgumentError on both truncated and invalid
  # input, so we treat any failure as "need more data" (the CAR format uses
  # well-formed varints; we will catch true malformation later as a truncation
  # error in finish/1).
  @spec decode_varint(binary()) :: {non_neg_integer(), binary()} | :need_more
  defp decode_varint(buffer) do
    LEB128.decode(buffer)
  rescue
    ArgumentError -> :need_more
  end

  # ---------------------------------------------------------------------------
  # Header parsing
  # ---------------------------------------------------------------------------

  @spec parse_header!(binary()) :: {pos_integer(), [CID.t()]}
  defp parse_header!(header_bin) do
    case DRISL.decode(header_bin) do
      {:ok, metadata, <<>>} ->
        validate_header_map!(metadata)

      {:ok, _, _leftover} ->
        raise "CAR stream: invalid header encoding (trailing bytes)"

      {:error, reason} ->
        raise "CAR stream: invalid header encoding (#{inspect(reason)})"
    end
  end

  @spec validate_header_map!(any()) :: {pos_integer(), [CID.t()]}
  defp validate_header_map!(metadata) when not is_map(metadata),
    do: raise("CAR stream: header is not a map")

  defp validate_header_map!(%{"version" => version}) when version != 1,
    do: raise("CAR stream: unsupported version #{version}")

  defp validate_header_map!(%{"version" => 1, "roots" => roots}) when is_list(roots) do
    unless Enum.all?(roots, &match?(%CID{}, &1)) do
      raise "CAR stream: header roots contain non-CID values"
    end

    {1, roots}
  end

  defp validate_header_map!(%{"version" => 1}),
    do: raise("CAR stream: header missing roots key")

  defp validate_header_map!(_),
    do: raise("CAR stream: header missing version key")

  # ---------------------------------------------------------------------------
  # Block parsing
  # ---------------------------------------------------------------------------

  @spec parse_block!(binary(), boolean()) :: {CID.t(), binary()}
  defp parse_block!(frame, verify) do
    if byte_size(frame) < @cid_byte_size do
      raise "CAR stream: block frame too short (#{byte_size(frame)} bytes)"
    end

    <<cid_bytes::binary-size(@cid_byte_size), data::binary>> = frame

    cid =
      case CID.decode(cid_bytes) do
        {:ok, fields} ->
          struct!(CID,
            version: fields.version,
            codec: fields.codec,
            hash_type: fields.hash_type,
            hash_size: fields.hash_size,
            digest: fields.digest,
            bytes: cid_bytes
          )

        {:error, reason} ->
          raise "CAR stream: invalid CID (#{inspect(reason)})"
      end

    if verify and not CID.verify?(cid, data) do
      raise "CAR stream: CID mismatch for block #{inspect(cid)}"
    end

    {cid, data}
  end
end
