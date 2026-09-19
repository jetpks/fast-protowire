# Changelog

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
