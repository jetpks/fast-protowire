# How encoding works

What happens between `message.encode` and the bytes, and why it's arranged that way.

## Compiled encoders

The first time an instance of a class is encoded, the class compiles its own `encode`
method from its field declarations (`Message.compile_encoder`). The generated source is one
block per field in field-number order:

```ruby
v0 = @name
if v0 && !v0.empty?
  ::Fast::Protowire::Wire.append_length_delimited(buffer, "\x0a", v0)
end
v2 = @type
if v2 && (v2.is_a?(Symbol) ? self.class.encoder_enums[2].resolve(v2) : v2) != 0
  buffer << "\x18"
  ::Fast::Protowire::Wire.append_varint(buffer, v2.is_a?(Symbol) ? self.class.encoder_enums[2].resolve(v2) : v2)
end
v3 = @metric
v3.each { |e| ::Fast::Protowire::Wire.append_length_delimited(buffer, "\x22", e.encode) }
```

The tag for each field is a frozen literal (the generated source carries an
`# encoding: ASCII-8BIT` magic comment, so the literals are binary), the presence guard is
inlined per rule and type, and fixed-width values use `Array#pack` with a `buffer:` so no
intermediate String is made. This is the same approach `protoc` takes for compiled
languages, and it removed most of the cost of the interpretive version: no dispatch on
rule or type per field, no method call to read the ivar, no separate omit check.

Declaring another field after the compile removes the method; the next `encode` compiles
again.

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
