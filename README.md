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

## Usage

Declarations mirror the `.proto` text:

```ruby
require "fast/protowire"

MetricType = Fast::Protowire::Enum.define(COUNTER: 0, GAUGE: 1, SUMMARY: 2, UNTYPED: 3, HISTOGRAM: 4)

class LabelPair < Fast::Protowire::Message
  syntax :proto2
  optional :name, :string, 1
  optional :value, :string, 2
end

class Counter < Fast::Protowire::Message
  syntax :proto2
  optional :value, :double, 1
end

class Metric < Fast::Protowire::Message
  syntax :proto2
  repeated :label, LabelPair, 1
  optional :counter, Counter, 3
end

class MetricFamily < Fast::Protowire::Message
  syntax :proto2
  optional :name, :string, 1
  optional :help, :string, 2
  optional :type, MetricType, 3
  repeated :metric, Metric, 4
end

family = MetricFamily.new(
  name: "http_requests_total", help: "Requests", type: :COUNTER,
  metric: [{ label: [{ name: "method", value: "GET" }], counter: { value: 12.0 } }]
)
bytes = family.encode
MetricFamily.decode(bytes) == family # => true
```

- `field` is a proto3 field with implicit presence: omitted when it holds
  its default. Under `syntax :proto2` it means `optional`.
- `optional` and `required` have explicit presence: `has_name?`,
  `clear_name`, and a value set to its default is still sent.
- `repeated` holds an Array; scalars pack by default under proto3, or with
  `packed: true`. `map` holds a Hash.
- `oneof :kind do ... end` groups fields; setting one clears the rest, and
  `message.kind` names the member that is set.
- A message type may be given as the class, or as a String naming a class
  in the same namespace, for recursive and forward references.
- Fields encode in field-number order, and unknown fields survive a
  decode/encode round trip, so bytes match what `protoc`-generated code and
  `google-protobuf` produce for the same values.

Streaming a large repeated field without building it all at once:

```ruby
tag = Fast::Protowire::Wire.tag(4, Fast::Protowire::Wire::LENGTH_DELIMITED) # MetricFamily.metric
buffer = MetricFamily.new(name: "wide", type: :COUNTER).encode
series.each do |labels, value|
  Fast::Protowire::Wire.append_length_delimited(buffer, tag, Metric.new(label: labels, counter: { value: value }).encode)
end
```

## Performance

Each message class compiles its own `encode` on first use: one straight-line
statement per field in number order, tags as frozen binary literals, no
per-field dispatch. Nested messages encode into a small buffer of their own
and are copied into the parent (Ruby's `String#insert` is O(size) on the
parent, so writing in place and inserting the length afterwards is slower).
A 36k-series Prometheus family with 12 labels per series (470k messages)
encodes in ~0.65 s on an M-series laptop, against ~0.5 s for google-protobuf's
native encoder, with no native allocation.

## Parity

`test/fast/protowire/parity.rb` builds every schema in `fixtures/proto`
with both this gem and `google-protobuf` from the same attributes and
asserts byte-identical output, decoding of each other's bytes, proto2
defaults and unpacked repeated fields, proto3 packing and presence rules,
oneofs, maps, recursion, `-0.0`, NaN, integer extremes and unknown-field
preservation.

## Development

```bash
bundle exec sus
bundle exec rubocop
```
