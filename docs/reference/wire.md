# Reference: Wire and Reader

The two primitives underneath `Message`, for code that wants to write or read the wire
format directly: streaming a large field, framing a delimited stream, or reading a value
without declaring its message.

## `Fast::Protowire::Wire`

Module functions. `buffer` is always a binary `String` that the function appends to and
returns.

Constants: `VARINT = 0`, `FIXED64 = 1`, `LENGTH_DELIMITED = 2`, `START_GROUP = 3`,
`END_GROUP = 4`, `FIXED32 = 5`.

| Signature | Returns | Notes |
|---|---|---|
| `tag(number, wire_type)` | frozen binary `String` | The key bytes for a field: `(number << 3) \| wire_type` as a varint. |
| `varint(value)` | binary `String` | `value` as a varint. Negative values are sign-extended to 64 bits (ten bytes), as `int32`/`int64` fields require. |
| `append_varint(buffer, value)` | `buffer` | Same, appended. |
| `zigzag32(value)` / `zigzag64(value)` | `Integer` | The zigzag mapping for `sint32`/`sint64`. |
| `unzigzag(value)` | `Integer` | Inverse of both. |
| `append_length_delimited(buffer, tag, bytes)` | `buffer` | `tag`, then the byte size of `bytes` as a varint, then `bytes`. Non-ASCII text is appended as its bytes. |
| `append_length_delimited_from(buffer, tag) { \|payload\| ... }` | `buffer` | Same, with the payload written by the block into a fresh buffer. |

## `Fast::Protowire::Reader`

A cursor over encoded bytes. `Reader.new(buffer, position = 0, limit = buffer.bytesize)`.

| Signature | Returns | Notes |
|---|---|---|
| `read_tag` | `[number, wire_type]` | |
| `read_varint` | `Integer` | Unsigned, up to 64 bits. |
| `read_fixed32` / `read_fixed64` | `Integer` | Unsigned little-endian. |
| `read_bytes(length)` | binary `String` | |
| `read_length_delimited` | binary `String` | A varint length, then that many bytes. |
| `read_packed` | `Reader` | A reader bounded to the next length-delimited value, for reading packed scalars until `eof?`. |
| `skip(wire_type)` | binary `String` | Skips one value of `wire_type`, groups included, and returns its raw bytes. |
| `eof?` | `Boolean` | |
| `position` | `Integer` | Byte offset. |

Every reader raises `Fast::Protowire::DecodeError` on truncated input, a varint longer
than ten bytes, or an unknown wire type.

## `Fast::Protowire::Field`

The object behind each declaration, reachable through `Message.fields`. Its public readers
are `name`, `number`, `type` (a scalar Symbol, `:enum` or `:message`), `rule`
(`:implicit`, `:optional`, `:required`, `:repeated`, `:map`), `oneof`, `enum`,
`message_class`, `wire_type`, `packed?`, `explicit_presence?` and `default_value`. It also
exposes `coerce(value)`, which validates and normalizes a value as assignment would, and
`encoder_step`, the closure `Message.compile_encoder` composes.
