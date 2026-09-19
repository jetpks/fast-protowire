# fast-protowire

The Protocol Buffers wire format for Ruby, with nothing on top of it: declare
a message's fields, get `encode` and `decode` for exactly those bytes.

It is not a replacement for `google-protobuf`. There are no descriptors,
no reflection, no JSON mapping and no generated code. It exists for
libraries that emit or read a fixed, known schema and want the memory cost
of doing so to be roughly the size of the encoded output, rather than a
native message object and arena for every field, as `google-protobuf`
allocates.

## Installation

```ruby
gem "fast-protowire"
```

`require "fast/protowire"` has no dependencies.

## Quickstart

Declarations mirror the `.proto` text. Run this with `bundle exec ruby` from a project
that has the gem:

```ruby
require "fast/protowire"

class LabelPair < Fast::Protowire::Message
  field :name, :string, 1
  field :value, :string, 2
end

class Counter < Fast::Protowire::Message
  field :value, :double, 1
end

class Metric < Fast::Protowire::Message
  repeated :label, LabelPair, 1
  field :counter, Counter, 3
end

metric = Metric.new(label: [{ name: "method", value: "GET" }], counter: { value: 12.0 })
bytes = metric.encode
Metric.decode(bytes) == metric # => true
```

Fields encode in field-number order, unknown fields survive a decode/encode round trip,
and the output is byte-identical to what `protoc`-generated code and `google-protobuf`
produce for the same values. The [tutorial](docs/tutorials/encode-a-message.md) walks
through a full schema and proves that.

## Documentation

### Tutorials

- [Tutorial: declare, encode and decode a message](docs/tutorials/encode-a-message.md) — declare a slice of the Prometheus client model, encode, decode, and check the bytes against google-protobuf.

### How-to guides

- [How to declare a schema from a .proto file](docs/how-to/declare-a-schema-from-proto.md) — the keyword-by-keyword translation, including proto2, oneofs, maps, packing and forward references.
- [How to stream a large repeated field](docs/how-to/stream-a-large-repeated-field.md) — append thousands of entries to a message without holding them all at once.
- [How to use declared messages with protocol-grpc](docs/how-to/use-with-protocol-grpc.md) — request and response classes for `protocol-grpc` and `async-grpc` stubs.
- [How to verify parity against google-protobuf](docs/how-to/verify-parity-against-google-protobuf.md) — add a case to the parity suite, or run the same check in your project.

### Reference

- [Reference: Message](docs/reference/message.md) — the declaration DSL, the instance API, and the errors.
- [Reference: field types](docs/reference/field-types.md) — every scalar type with its wire type, Ruby value, range, presence and packing rules; enums.
- [Reference: Wire and Reader](docs/reference/wire.md) — the primitives for writing and reading the wire format directly.

### Explanation

- [Design: the wire format and nothing else](docs/explanation/design.md) — what google-protobuf costs per message, what this gem does instead, and what it leaves out.
- [How encoding works](docs/explanation/encoding.md) — compiled encoders, buffers, field order, presence, and decoding.

## Development

```bash
bundle exec sus
bundle exec rubocop
```
