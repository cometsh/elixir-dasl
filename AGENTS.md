# AGENTS.md

Guidance for agentic coding assistants working in this repository.

## Project Overview

`elixir-dasl` is an Elixir library implementing DASL (Decentralized
Authenticated Structure Layer) primitives: CIDs, DRISL (CBOR profile), and CAR
archives.

## Build / Lint / Test Commands

```bash
# Compile
mix compile

# Format (run before committing)
mix format

# Check formatting without writing
mix format --check-formatted

# Lint
mix credo

# Run all tests
mix test

# Run a single test file
mix test test/dasl/cid_test.exs

# Run a single test by line number
mix test test/dasl/cid_test.exs:42

# Run doctests only
mix test --only doctest

# Generate docs
mix docs
```

No custom Mix aliases are defined. There is no CI pipeline — validate locally.

## Project Structure

```
lib/dasl/
  cid.ex                 # DASL.CID — struct, parse/encode/verify/compute
  drisl.ex               # DASL.DRISL — facade
  drisl/
    decoder.ex           # DASL.DRISL.Decoder
    encoder.ex           # DASL.DRISL.Encoder
  car.ex                 # DASL.CAR — struct + entry-point API
  car/
    decoder.ex           # DASL.CAR.Decoder
    encoder.ex           # DASL.CAR.Encoder
    stream_decoder.ex    # DASL.CAR.StreamDecoder
    drisl.ex             # DASL.CAR.DRISL

test/dasl/               # mirrors lib/dasl/ exactly
```

## Code Style

### Module Naming

- Domain acronyms are all-caps: `DASL`, `CAR`, `CID`, `DRISL`.
- Sub-modules follow `Parent.Role`: `DASL.CAR.Decoder`, `DASL.CAR.Encoder`.
- Module file path mirrors module name exactly.

### Structs

Use `TypedStruct` with `enforce: true` for all structs. Every field must be
typed. Use `default:` only where a sensible zero value exists.

```elixir
typedstruct enforce: true do
  field :version, pos_integer(), default: 1
  field :roots, list(CID.t()), default: []
  field :blocks, %{CID.t() => binary()}, default: %{}
end
```

### Typespecs

- Every public function must have `@spec`.
- Every private function should have `@spec` where non-trivial.
- Define named error type aliases at the top of each module, then reference them
  in `@spec` annotations:

```elixir
@type header_error() :: {:error, :header, atom()}
@type block_error()  :: {:error, :block, atom()}
@type decode_error() :: header_error() | block_error()
```

### Error Handling

Consistent tagged-tuple convention — do not deviate:

- Success: `{:ok, value}`
- Simple error: `{:error, reason}`
- Scoped error (CAR layer): `{:error, :scope, :reason}` — e.g.
  `{:error, :header, :missing_roots}`, `{:error, :block, :cid_mismatch}`

Use `with` chains for multi-step fallible operations; use `else` to remap errors
when needed. Use `Enum.reduce_while` for fallible iteration — halt on first
error.

Bang variants (`parse_header!`, `validate_block!`) are only acceptable inside
`StreamDecoder`-style modules where the documented contract is raise-on-error.
Do not mix raise and tuple-return styles in the same module without explicit
documentation of the contract.

### Pattern Matching and Guards

- Prefer multi-clause function heads for exhaustive dispatch over nested
  conditionals.
- Use bit-syntax binary pattern matching for low-level binary parsing (see
  `DRISL.Decoder`).
- Pair guards with pattern matches for validation constraints:

```elixir
when hash_size == @hash_size and byte_size(digest) == @hash_size
```

### Module Attributes for Constants

Use `@` module attributes for all magic numbers and codec identifiers. Group
them at the top of the module, after `@moduledoc`.

```elixir
@codec_raw   0x55
@codec_drisl 0x71
@hash_sha256 0x12
@hash_size   32
```

### Pipes

Use pipes where they read naturally. Do not force them. Prefer `with` over pipes
for error-prone chains. The primary pipe use-case is stream pipelines:

```elixir
chunk_stream
|> StreamDecoder.decode_stream(opts)
|> Stream.map(&transform/1)
```

### Documentation

- Every public module must have `@moduledoc` with a prose description and, where
  applicable, a `Spec: <url>` line linking to the relevant spec.
- Every public function must have `@doc` with:
  - A prose description. Keep it high-level — do not repeat details already
    covered by the spec (e.g. byte-level encoding rules, magic constants,
    algorithm steps).
  - An `## Options` section if the function accepts an options keyword list.
  - An `## Examples` section with `iex>` doctests for the happy path and at
    least one error case.
- Use dashes (`-`) for all Markdown lists in `@moduledoc` and `@doc`. Never use
  asterisks (`*`).

### Protocol Implementations

Implement `String.Chars` and `Inspect` for domain structs at the **bottom** of
the file, outside the main module block — see `cid.ex` for the pattern.

### Streaming

Use `Stream.transform/4` with explicit start/reduce/after arities (not the
3-arity shorthand) for stateful streaming parsers.

### Section Separators

Use `# ---...---` comment separators (78 dashes) to group related functions
visually, consistent with existing source files.

## Test Style

- All test modules: `use ExUnit.Case, async: true`.
- Pull doctests in at the top: `doctest DASL.ModuleName`.
- Use `describe/test` blocks — one `describe` per public function or logical
  group.
- Shared fixtures: define as `@` module attributes or `defp` helpers at the top
  of the test module with a brief comment on their purpose.
- Assertions use pattern matching: `assert {:ok, _} = ...`, not
  `{:ok, val} = ...; assert val == ...`.
- For stream decoder raise tests:
  `assert_raise RuntimeError, ~r/pattern/, fn -> ... end`.
- Do not couple decoder tests to encoder correctness — construct raw binaries
  directly in test helpers when testing a decoder in isolation.
- Test file paths must mirror `lib/` paths exactly.

## Dependencies

| Dep            | Purpose                       |
| -------------- | ----------------------------- |
| `:cbor`        | CBOR encode/decode            |
| `:typedstruct` | Typed struct DSL              |
| `:varint`      | Unsigned varint encode/decode |
| `:ex_doc`      | Doc generation (dev only)     |
| `:credo`       | Static analysis (dev + test)  |

No Dialyzer setup. No property-based testing. Do not add new dependencies
without discussion — the dep surface is intentionally minimal.

## Formatter

`.formatter.exs` imports `:typedstruct` so `typedstruct do ... end` blocks
format correctly. Default line length (98) applies. Always run `mix format`
before committing.
