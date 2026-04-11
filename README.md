# elixir-dasl

An Elixir implementation of [DASL](https://dasl.ing/) primitives.

## Overview

**DASL** (Decentralized Authenticated Structure Layer) is a family of
specifications for content-addressed data that is interoperable with the broader
IPFS/IPLD ecosystem while remaining minimal and self-contained.

This library provides:

- `DASL.CID`: content identifiers, a compact, self-describing pointer to a piece
  of data.
- `DASL.DRISL`: deterministic CBOR serialization.
- `DASL.CAR`: Content-Addressable aRchive encoding and decoding, as well as a
  stream decoder.
- `DASL.CAR.DRISL`: a higher-level CAR variant where block values are Elixir
  terms rather than raw binaries, and are encoded/decoded via DRISL
  transparently.

## Quick start

```elixir
# CIDs
cid = DASL.CID.compute("hello world")
DASL.CID.verify?(cid, "hello world")  # => true
DASL.CID.encode(cid)                  # => "bafkrei..."

# Round-trip a CID string
{:ok, cid} = DASL.CID.new("bafkreifzjut3te2nhyekklss27nh3k72ysco7y32koao5eei66wof36n5e")

# DRISL encode/decode
{:ok, bin} = DASL.DRISL.encode(%{"key" => [1, 2, 3]})
{:ok, term, ""} = DASL.DRISL.decode(bin)

# Build and encode a CAR archive
{car, cid1} = DASL.CAR.add_block(%DASL.CAR{}, "block one")
{car, cid2} = DASL.CAR.add_block(car, "block two")
{:ok, car}  = DASL.CAR.add_root(car, cid1)
{:ok, bin}  = DASL.CAR.encode(car)

# Decode it back
{:ok, car} = DASL.CAR.decode(bin)

# Stream a large CAR file
File.stream!("large.car", 65_536)
|> DASL.CAR.stream_decode()
|> Enum.each(fn
  {:header, _version, roots} -> IO.inspect(roots, label: "roots")
  {:block, cid, _data}       -> IO.inspect(cid,   label: "block")
end)
```

## Installation

Get elixir-dasl from [hex.pm](https://hex.pm) by adding it to your `mix.exs`:

```elixir
def deps do
  [
    {:dasl, "~> 0.1"}
  ]
end
```

Documentation can be found on HexDocs at https://hexdocs.pm/dasl.

---

This project is licensed under the [MIT License](./LICENSE).
