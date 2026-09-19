# Reference: Wire and Reader

The two primitives underneath `Message`, for code that wants to write or read the wire
format directly: streaming a large field, framing a delimited stream, or reading a value
without declaring its message.

## `Fast::Protowire::Wire`

Module functions. `buffer` is always a binary `String` that the function appends to and,
unless noted, returns.

Constants: `VARINT = 0`, `FIXED64 = 1`, `LENGTH_DELIMITED = 2`, `START_GROUP = 3`,
`END_GROUP = 4`, `FIXED32 = 5`.

| Signature | Returns | Notes |
|---|---|---|
| `tag(number, wire_type)` | frozen binary `String` | The key bytes for a field: `(number << 3) \| wire_type` as a varint. |
| `varint(value)` | binary `String` | `value` as a varint. Negative values are sign-extended to 64 bits (ten bytes), as `int32`/`int64` fields require. |
| `append_varint(buffer, value)` | `buffer` | Same, appended. |
| `varint_size(value)` | `Integer` | The bytes `append_varint` would write. |
| `zigzag32(value)` / `zigzag64(value)` | `Integer` | The zigzag mapping for `sint32`/`sint64`. |
| `unzigzag(value)` | `Integer` | Inverse of both. |
| `append_bytes(buffer, bytes)` | `buffer` | `bytes` appended as bytes whatever their encoding; the buffer stays binary. |
| `append_length_delimited(buffer, tag, bytes)` | `buffer` | `tag`, then the byte size of `bytes` as a varint, then `bytes`. |
| `append_length_delimited_from(buffer, tag, width = 1) { \|buffer\| ... }` | `Integer` | `tag`, then a length prefix, then whatever the block appends to `buffer`, written in place: the prefix is reserved at `width` bytes, filled in after the block, and resized first if the payload needs a different width. Returns the width written; pass it back as `width` when writing many alike values and the prefix is rarely resized. |
| `reserve_length(buffer, width = 1)` | `Integer` | Appends `width` placeholder bytes for a length prefix and returns the position after them. |
| `close_length(buffer, start, width = 1)` | `Integer` | Writes the varint size of everything appended since `start` into the placeholder before it, resizing the placeholder when the size needs a different width. Returns the width written. |

Growing a String in place (`bytesplice`, `insert`) makes Ruby reallocate it to exactly its
new size, so on a large buffer a resized prefix costs a reallocation rather than the bytes
moved. That is what the `width` hint avoids; see [How encoding works](../explanation/encoding.md#buffers).

## `Fast::Protowire::Reader`

A cursor over encoded bytes. `Reader.new(buffer, position = 0, limit = buffer.bytesize)`.

| Signature | Returns | Notes |
|---|---|---|
| `read_tag` | `[number, wire_type]` | |
| `read_varint` | `Integer` | Unsigned, up to 64 bits. |
| `read_fixed32` / `read_fixed64` | `Integer` | Unsigned little-endian. |
| `read_fixed(format, width)` | the unpacked value | `width` bytes as one value of the `Array#pack` `format`, read in place. |
| `read_bytes(length)` | binary `String` | |
| `read_length_delimited` | binary `String` | A varint length, then that many bytes. |
| `read_nested { \|reader\| ... }` | the block's value | Bounds the reader to the next length-delimited value for the block, then continues after it. How nested messages, packed fields and map entries are read, with no copy of their bytes. |
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
