# How encoding works

What happens between `message.encode` and the bytes, and why it's arranged that way.

## Compiled encoders

The first time an instance of a class is encoded, the class compiles its own `encode`
method from its field declarations (`Message.compile_encoder`). Each field contributes one
*step*, a lambda taking the message and the buffer, built once with everything it needs
captured: the ivar name, the tag bytes, the enum module, the writer for the field's type,
and the guard that decides whether the field is written at all. `encode` is then
`define_method` over the steps in field-number order:

```ruby
steps = sorted_fields.map(&:encoder_step)
define_method(:encode) do |buffer = String.new|
  steps.each { |step| step.call(self, buffer) }
  buffer << @unknown_fields if @unknown_fields
  buffer
end
```

All the dispatch on rule and type happens when a step is built, not on every encode; what
runs per field is one ivar read, one guard and one writer. Fixed-width values use
`Array#pack` with a `buffer:` so no intermediate String is made. Declaring another field
after the compile removes the method; the next `encode` compiles again.

An earlier version generated the method's source as a String and `class_eval`ed it, one
straight-line statement per field, as `protoc` does for compiled languages. That was
faster (0.23 s against 0.35 s to encode a 36k-series family's pre-built objects, 0.63 s
against 0.75 s for the whole render), but it was Ruby in strings: unreviewable without
capturing the generated source, and dependent on escaping binary tag literals correctly.
The closure form was chosen as the readable reference; the generated form can return
behind the same interface if the difference ever matters.

## Buffers

A message encodes into one buffer, the one passed to `encode` or a fresh String when none is,
and everything nested in it goes into that same buffer. A length-delimited value's prefix
comes before bytes whose length isn't known until they are written, so the writer appends a
placeholder for the prefix, encodes the payload in place, and fills the prefix in afterwards
with `String#setbyte` (`Wire.reserve_length` and `Wire.close_length`, or the two together as
`Wire.append_length_delimited_from`). When the payload turns out to need a prefix of a
different width, the placeholder is resized with `String#bytesplice`, which moves only the
payload's bytes.

Each writer remembers the width its last value needed and reserves that next time, so a
repeated field whose entries are alike (every `Metric` in a family, every `LabelPair` in a
metric) almost never resizes. The hint matters more than it looks: Ruby reallocates a String
it grows in place to exactly its new size, and on a large buffer that reallocation, not the
bytes moved, is what a resize costs. Nested messages, packed repeated fields and map entries
all encode this way, so encoding allocates nothing per message: a family of 36,000 metrics
encodes in one object, its output. The earlier design, a small String per nested message
copied into the parent, cost an object and a copy per message and was slower.

Fixed-width values are written with `Array#pack` into the buffer, one lambda per format so
that the format is a literal: Ruby elides the temporary Array for `[value].pack(literal,
buffer:)`, from 3.4, and only then. Text goes in with `String#append_as_bytes` on Ruby 3.4 and
later, tag, one-byte size and payload in one call, so a UTF-8 value costs no binary copy;
before 3.4, non-ASCII text is copied to binary first, as Ruby's encoding rules require.
`test/fast/protowire/allocations.rb` holds these budgets.

## What is written, in what order

Fields are written in ascending field-number order, whatever order they were declared in.
Unknown fields kept from a decode are appended after every declared field. Both match the
reference encoder, which writes its buffer backwards from the last field to the first and
places unknown fields at the very end.

Presence decides whether a field is written at all; [Reference: field types](../reference/field-types.md)
tabulates the rules. Two are easy to get wrong and are pinned by the parity suite: a
proto3 implicit `double` compares its bits, not its value, so `-0.0` is written while `0.0`
is not; and a oneof member always has presence, so a `string` member set to `""` is
written.

## Decoding

`decode` is interpretive: read a tag, look up the field by number, read a value of the
field's wire type, store it. Repeated scalars are accepted packed or unpacked whatever the
declaration says. A second occurrence of a scalar replaces the first; of a repeated field,
appends; of a nested message, merges into the existing one. A tag the class doesn't
declare is skipped by wire type (groups included) and its raw bytes kept, so `encode` can
write it back. Two more things take that same path, because the reference puts them there
rather than raising: a declared field arriving with a wire type it doesn't accept, which is
schema drift and not corruption; and a map entry carrying more than a key and a value — an
undeclared subfield, or a key or value with a wire type the entry doesn't accept. Such an
entry is not a map entry, so the map is left alone and the entry is written back the way the
reference writes it, the subfields it did carry first (in number order, omitted when at
their default) and then the bytes it carried besides. Decoding isn't compiled because it
isn't on anyone's hot path yet; it would be the same technique if it were.

It does read in place. A nested message, packed field or map entry narrows the reader to
its own bytes for the duration (`Reader#read_nested`, or `#read_packed` for the packed
field, which holds scalars and so costs no nesting level) instead of slicing them out into a
String and a second reader; fixed-width values are unpacked at an offset rather than from a
slice; tags are split from the key without an Array for the pair. What a decode allocates
is the messages, their containers and their Strings, and nothing else.
