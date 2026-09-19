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

A nested message encodes into a small String of its own, which is then appended to the
parent with its length prefix. Writing the child straight into the parent and inserting the
length afterwards avoids that String, but Ruby's `String#insert` costs time proportional to
the whole parent buffer wherever the insert lands, so on a large message it's far slower.
Small per-message buffers and one copy each are cheap.

The same applies to packed repeated fields and map entries: each is written into a
temporary buffer, then appended.

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
write it back. Decoding isn't compiled because it isn't on anyone's hot path yet; it
would be the same technique if it were.
