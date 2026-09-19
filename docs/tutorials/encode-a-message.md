# Tutorial: declare, encode and decode a message

In this tutorial we declare a small schema with fast-protowire, encode a message to
bytes, decode it back, and check the bytes against `google-protobuf`. By the end you'll
have a working encoder for a real Protocol Buffers schema and a test that proves it
produces the reference implementation's bytes.

You'll need Ruby 3.3 or later. `google-protobuf` is only used in the last step, to
compare against; nothing in the library needs it.

Work in a new, empty directory for the rest of this tutorial.

## 1. Create the Gemfile

```ruby
# frozen_string_literal: true

source "https://rubygems.org"

gem "fast-protowire"
gem "google-protobuf"
```

Run `bundle install`.

If you're working against an unreleased checkout of fast-protowire instead of the
published gem, replace its line with `gem "fast-protowire", path: "/path/to/fast-protowire"`.

## 2. Pick a schema

We'll use a slice of the Prometheus client model, the format a Prometheus server reads
when it scrapes protobuf. Save it as `metrics.proto` (you'll compile it in step 6):

```proto
syntax = "proto3";

package tutorial;

enum MetricType {
  COUNTER = 0;
  GAUGE = 1;
}

message LabelPair {
  string name = 1;
  string value = 2;
}

message Counter {
  double value = 1;
}

message Metric {
  repeated LabelPair label = 1;
  Counter counter = 3;
}

message MetricFamily {
  string name = 1;
  string help = 2;
  MetricType type = 3;
  repeated Metric metric = 4;
}
```

## 3. Declare it

Create `metrics.rb`. Each `message` becomes a class, each `enum` an `Enum.define`, and
each field line becomes one declaration with the same name, type and number:

```ruby
# frozen_string_literal: true

require "fast/protowire"

module Tutorial
  MetricType = Fast::Protowire::Enum.define(COUNTER: 0, GAUGE: 1)

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

  class MetricFamily < Fast::Protowire::Message
    field :name, :string, 1
    field :help, :string, 2
    field :type, MetricType, 3
    repeated :metric, Metric, 4
  end
end
```

`field` is a proto3 field: it's omitted from the output when it holds its default value.
Message-typed fields and `repeated` fields take the class directly.

## 4. Encode a message

Create `encode.rb`:

```ruby
# frozen_string_literal: true

require_relative "metrics"

family = Tutorial::MetricFamily.new(
  name: "http_requests_total",
  help: "Total HTTP requests",
  type: :COUNTER,
  metric: [
    { label: [{ name: "method", value: "GET" }], counter: { value: 12.0 } },
    { label: [{ name: "method", value: "POST" }], counter: { value: 3.0 } }
  ]
)

bytes = family.encode
puts bytes.bytesize
puts bytes.unpack1("H*")
```

Run `bundle exec ruby encode.rb`. You'll see `99` and a hex dump beginning with `0a13687474`:
field 1 (`0a`), 19 bytes (`13`), then `http_requests_total`. Nested hashes built the
`Metric`, `LabelPair` and `Counter` messages for you; passing instances works the same.

Notice what is *not* in the dump: `type` is `COUNTER`, which is value 0, so under proto3
rules it isn't written at all.

## 5. Decode it back

Add to `encode.rb`:

```ruby
decoded = Tutorial::MetricFamily.decode(bytes)
puts decoded.name
puts decoded.metric.map { |m| "#{m.label.first.value}=#{m.counter.value}" }.join(" ")
puts decoded == family
```

Run it again. The last three lines are `http_requests_total`, `GET=12.0 POST=3.0` and
`true`: a decoded message compares equal to the one it was encoded from.

## 6. Prove the bytes against google-protobuf

Compile the schema with `protoc` (`brew install protobuf` or your package manager):

```
protoc --ruby_out=. metrics.proto
```

This writes `metrics_pb.rb`, which declares the same messages under `Tutorial::` using
`google-protobuf`. Because both libraries want the `Tutorial` namespace, load the
generated file under a different one. Create `parity.rb`:

```ruby
# frozen_string_literal: true

require_relative "metrics"

module Reference
  require "google/protobuf"
  module_eval(File.read("metrics_pb.rb").gsub("module Tutorial", "module Reference::Tutorial"))
end

attributes = {
  name: "http_requests_total", help: "Total HTTP requests", type: :COUNTER,
  metric: [{ label: [{ name: "method", value: "GET" }], counter: { value: 12.0 } }]
}

ours = Tutorial::MetricFamily.new(attributes).encode
theirs = Reference::Tutorial::MetricFamily.new(attributes).to_proto

puts ours == theirs
puts Reference::Tutorial::MetricFamily.decode(ours).metric.first.counter.value
```

Run `bundle exec ruby parity.rb`: `true`, then `12.0`. The same attributes produce the same
bytes with either library, and the reference decoder reads ours.

## What you've built

A dependency-free encoder and decoder for a real schema, checked byte-for-byte against the
reference implementation. From here:

- [How to declare a schema from a .proto file](../how-to/declare-a-schema-from-proto.md)
  covers every keyword the DSL maps, including proto2, oneofs, maps and packing.
- [How to stream a large repeated field](../how-to/stream-a-large-repeated-field.md) shows
  how to write thousands of `Metric` entries without holding them all at once.
- [Reference: Message](../reference/message.md) lists everything a declared class can do.
