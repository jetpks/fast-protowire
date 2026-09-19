# How to verify parity against google-protobuf

Add a case to the parity suite, or run the same check in your own project, so that a
declaration is proven to produce the reference implementation's bytes. You need `protoc`
and the `google-protobuf` gem in your test group.

## Steps

1. Put the schema in a `.proto` file. In this repository the files live under
   `fixtures/proto`; add fields or messages to `parity3.proto` (proto3) or
   `parity2.proto` (proto2) rather than starting a new file, so the mirror stays in one
   place.

2. Regenerate the reference classes:

   ```
   protoc --proto_path=fixtures/proto --ruby_out=fixtures/pb fixtures/proto/*.proto
   ```

   The generated `*_pb.rb` files are checked in; `fixtures/reference.rb` loads them.

3. Mirror the change in `fixtures/schema.rb`, keeping the package, message and field
   names identical so one attributes Hash builds both sides.

4. Add attributes to `fixtures/cases.rb`. Each Hash must be valid input for both
   `Mirror3::X.new` and `Parity3::X.new`: nested Hashes for messages, Arrays for
   repeated fields, Symbols or Integers for enums, Hashes for maps. Include the edge you
   care about: the default value, an empty container, an out-of-order map, a negative
   number.

5. Run `bundle exec sus`. The parity test asserts, for every case, that `encode` equals
   `to_proto`, that our decode of their bytes equals our message, and that their decode of
   our bytes equals theirs.

## In your own project

The same check needs no fixtures machinery:

```ruby
attributes = { name: "x", count: 3 }
ours = MyMessage.new(attributes).encode
theirs = Reference::MyMessage.new(attributes).to_proto
raise "bytes differ" unless ours == theirs
```

Load the generated file under a separate namespace if it uses the same module name as your
declarations (see step 6 of the
[tutorial](../tutorials/encode-a-message.md#6-prove-the-bytes-against-google-protobuf)).

## What parity does not cover

Maps with more than one entry: `google-protobuf` writes entries in its hash table's order,
fast-protowire in insertion order. Both decode each other's bytes to equal messages, which
is what the suite asserts for multi-entry maps.
