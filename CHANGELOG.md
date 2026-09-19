# Changelog

## 0.3.0

- A declared field arriving with a wire type it does not accept is kept as
  an unknown field and written back verbatim, where it used to raise
  `DecodeError`: schema drift is not corruption, and the reference keeps it.
  So is a map entry carrying more than a key and a value — an undeclared
  subfield, or a key or value with a wire type the entry does not accept —
  kept whole among the parent message's unknown fields and left out of the
  map. An entry that omits its key or its value decodes to that type's
  default, an empty message for a message-typed value.
- Hostile input is bounded rather than fatal. Nesting deeper than
  `Reader::MAX_DEPTH` (100, the reference's limit; nested messages, map
  entries and groups count, a packed field does not) raises `DecodeError`
  instead of overflowing the VM stack with `SystemStackError`. Field number
  0 anywhere in the input, a group closed by an `END_GROUP` carrying another
  number, and a proto3 `string` whose bytes are not valid UTF-8 raise
  `DecodeError` too. A varint carrying bits above 64 is truncated rather
  than read wide, as every implementation does, and a `sint32` is truncated
  to 32 bits before its zigzag is undone.
- Decoding is about bytes, so a `Reader` reads its input whatever the String
  is tagged: a non-binary one is read through a binary view made once on
  construction, and the input is never modified. `encode` holds its buffer
  to the same rule: an empty String of any encoding is retagged binary, and
  one already holding text raises `ArgumentError` rather than widening the
  bytes it appends into that encoding's characters.
- `Message#==`, `eql?` and `hash` compare the declared fields only. Unknown
  fields are no longer part of the comparison, as the reference does not
  compare them; they are still kept, still readable through
  `unknown_fields`, and still written back by `encode`. Byte identity is
  `a.encode == b.encode`.
- A `float` field narrows to single precision on assignment rather than on
  encode, so what it reads back is what the wire carries and
  `decode(encode(m)) == m` holds: `0.1` reads back `0.10000000149011612`,
  `3.5e38` reads `Infinity`, `1e-50` reads `0.0`. A 32-bit NaN is still
  written canonical (`7fc00000`) because Ruby's `pack("e")` drops the sign
  and payload bits the reference preserves; that one is documented, not
  fixed. `double` NaNs round-trip whole.
- A declaration the wire format has no form for raises `ArgumentError` where
  it is written rather than at the first encode: a field number outside
  1 ... 2²⁹−1 or inside 19000 ... 19999, which the specification reserves for
  the implementation, and `packed: true` on a `string`, `bytes` or message
  field.
- `Reader#read_packed` is back for packed fields, which are read in place
  and cost no depth level (0.2.0's entry recorded it removed).
  `Reader#read_key` returns a tag as the raw key holding number and wire
  type together; `Reader#skip` takes the field number the value arrived
  under, `skip(wire_type, number = nil)`, so a group is closed only by its
  own number; `Field#accepts?(wire_type)`, `Wire.binary_buffer` and
  `Wire::UINT64_MASK` are public.
- Decoding costs what it did on 0.2.0, guards included: the 36,000-metric
  family decodes in 0.801 s where 0.2.0 takes 0.784 s on the same machine
  and Ruby (4.0.7, five timed calls, same session). A field's wire type is
  computed once, when the field is declared, rather than on every read,
  where the per-field check had been paying for it twice. What it allocates
  is unchanged, 1,404,005 objects for that family and one object to encode
  it, and so are the budgets in `test/fast/protowire/allocations.rb`; the
  benchmarks page carries the re-measured tables.

## 0.2.0

- Encoding allocates nothing per nested message, packed field or map
  entry: each is written into the parent buffer behind a length prefix
  filled in afterwards. A family of 36,000 metrics x 12 labels encodes in
  one object, its output, where it took 647,000, and 22% faster.
  `Wire.append_length_delimited_from` now appends in place and returns the
  width of the prefix it wrote, a hint to pass back for the next value;
  `Wire.reserve_length` and `Wire.close_length` are its pieces, and
  `Wire.varint_size` and `Wire.append_bytes` are public.
- Fixed-width values pack with literal formats, so a double costs no Array
  on Ruby 3.4+; text is appended with `String#append_as_bytes` there, tag
  and one-byte size in the same call and no binary copy for UTF-8.
  Zigzag no longer allocates for negative values.
- Decoding reads nested messages, packed fields and map entries in place
  (`Reader#read_nested`), unpacks fixed-width values at an offset
  (`Reader#read_fixed`) and splits tags without an Array, so it allocates
  only the messages, containers and Strings it returns: the same family
  decodes in 1.4M objects where it took 7.1M, 1.7x faster.
- `Message.new` no longer allocates an empty keyword Hash per message.
- Removed: `Reader#read_packed` (use `read_nested`) and the interpretive
  `Field#encode`, which the compiled encoder had superseded.
- `test/fast/protowire/allocations.rb` holds the budgets; the Prometheus
  client model (`fixtures/proto/metrics.proto`, upstream `client_model`)
  joins the parity suite; `benchmark/messages.rb` measures encode, build
  and decode against google-protobuf, published on the benchmarks page.

## 0.1.0

- Initial release: `Wire`, `Reader`, `Enum` and the `Message` DSL covering
  every scalar type, proto2 and proto3 presence, packed and unpacked
  repeated fields, maps, oneofs, nested and recursive messages, unknown
  field preservation and merge-on-decode, verified byte-for-byte against
  `google-protobuf`. `encode` is compiled per message class.
