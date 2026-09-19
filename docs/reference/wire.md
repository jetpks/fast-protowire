# Reference: Wire and Reader

The two primitives underneath `Message`, for code that wants to write or read the wire
format directly: streaming a large field, framing a delimited stream, or reading a value
without declaring its message.

## `Fast::Protowire::Wire`

Module functions. `buffer` is always a binary `String` that the function appends to and,
unless noted, returns.

Constants: `VARINT = 0`, `FIXED64 = 1`, `LENGTH_DELIMITED = 2`, `START_GROUP = 3`,
`END_GROUP = 4`, `FIXED32 = 5`, `UINT64_MASK = 2⁶⁴−1`.

| Signature | Returns | Notes |
|---|---|---|
| `binary_buffer(buffer)` | `buffer` | Checks a caller's buffer: a binary one passes, an empty one of any encoding is retagged binary, and a non-binary one already holding text raises `ArgumentError`. Appending a byte to a text String appends that encoding's character for it instead, so every buffer here has to be bytes. `Message#encode` calls this on the buffer it's given. |
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
The buffer is read as bytes whatever it is tagged: a non-binary String is copied into a
binary view once, on construction, so every slice below comes back binary and the input is
left alone. `Reader::MAX_DEPTH` (100, the reference's limit) bounds how deep nested messages,
map entries and groups may go — the values read by recursing into them. A packed field holds
scalars and costs no level, so a packed field at depth 100 reads.

| Signature | Returns | Notes |
|---|---|---|
| `read_tag` | `[number, wire_type]` | |
| `read_key` | `Integer` | The tag as its raw key, number and wire type together. Field number 0 raises `DecodeError`: no field has it, and the reference rejects it wherever it appears. |
| `read_varint` | `Integer` | Unsigned, 64 bits: a tenth byte carries only bit 64's worth and anything above is truncated, as every implementation does. |
| `read_fixed32` / `read_fixed64` | `Integer` | Unsigned little-endian. |
| `read_fixed(format, width)` | the unpacked value | `width` bytes as one value of the `Array#pack` `format`, read in place. |
| `read_bytes(length)` | binary `String` | |
| `read_length_delimited` | binary `String` | A varint length, then that many bytes. |
| `read_packed { \|reader\| ... }` | the block's value | Bounds the reader to the next length-delimited value for the block, then continues after it, with no copy of its bytes. How a packed repeated field is read. |
| `read_nested { \|reader\| ... }` | the block's value | The same, for a value read by recursing into it: a nested message or a map entry. Counts the nesting, so past `MAX_DEPTH` it raises rather than letting the recursion overflow the VM stack. |
| `skip(wire_type, number = nil)` | binary `String` | Skips one value of `wire_type`, groups included, and returns its raw bytes. `number` is the field number the value arrived under: a group is closed by an `END_GROUP` carrying its own number and nothing else, and anything else raises `DecodeError`. Without one, any `END_GROUP` closes it. Nested groups count against `MAX_DEPTH` too. |
| `eof?` | `Boolean` | |
| `position` | `Integer` | Byte offset. |

Every reader raises `Fast::Protowire::DecodeError` on truncated input, a varint longer
than ten bytes, an unknown wire type, field number 0, a group closed by another number, or
nesting past `MAX_DEPTH`.

## `Fast::Protowire::Field`

The object behind each declaration, reachable through `Message.fields`. Its public readers
are `name`, `number`, `type` (a scalar Symbol, `:enum` or `:message`), `rule`
(`:implicit`, `:optional`, `:required`, `:repeated`, `:map`), `oneof`, `enum`,
`message_class`, `wire_type`, `packed?`, `explicit_presence?` and `default_value`. It also
exposes `accepts?(wire_type)` — whether a value of that wire type can be read into the
field, which for a packable `repeated` field means the packed and the unpacked form alike —
`coerce(value)`, which validates and normalizes a value as assignment would, and
`encoder_step`, the closure `Message.compile_encoder` composes.
