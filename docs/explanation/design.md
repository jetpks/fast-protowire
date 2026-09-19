# Design: the wire format and nothing else

fast-protowire exists because `google-protobuf` is the wrong shape for one common job:
serializing many small, short-lived messages of a fixed schema.

## What google-protobuf costs per message

The gem is a Ruby binding over `upb`, Google's C protobuf runtime. Every `Message.new`
allocates a native arena and a Ruby wrapper object for the arena, registers the message in
a process-wide `ObjectSpace::WeakMap` keyed by pointer, and attaching a message to a parent
fuses their arenas so neither can be freed until both are unreachable. A `LabelPair` whose
wire form is 51 bytes costs about a kilobyte of memory and three Ruby-visible objects to
build. Encoding a Prometheus scrape of 36,000 series through it allocated ~320 MiB per
render, of which the output was 23 MB.

None of that is wasteful for what the runtime was built to do: long-lived messages that
are mutated, read field by field, compared and reflected on. It's the wrong trade for
"build, encode once, discard".

## What this gem does instead

A declared class is plain Ruby: an object with one instance variable per field. `encode`
is a method compiled from the declaration into straight-line code, one statement per
field, that appends bytes to a String. `decode` walks tags and assigns. There is nothing
native, no registry of live objects, and the memory cost of encoding is the output plus
whatever short-lived objects you built to describe it.

The price is scope. There are no descriptors, so there is no reflection, no
`DescriptorPool`, no JSON mapping, no text format, no well-known-type conveniences, and no
support for the `protoc --ruby_out` output that the rest of the Ruby protobuf ecosystem
produces. Gems that require `google-protobuf` still require it. This gem is for libraries
that own their schema and want it to cost bytes.

## Why a DSL and not generated code

For a fixed schema, hand-declared classes are shorter than generated ones, read like the
`.proto` they came from, and can be reviewed as such. A `protoc` plugin that emits the same
declarations from a `.proto` would be a natural addition, and the DSL is designed so that
generated code would look exactly like the hand-written kind. It is not written yet.

## Why parity is the specification

The wire format has a written specification, but the reference implementation's choices
fill in everything the specification leaves open: whether `-0.0` counts as a default,
where unknown fields go on re-encode, how a oneof member set to zero is treated. Rather
than argue from the text, the test suite builds every schema it ships with both libraries
from the same attributes and requires identical bytes. That is the contract: for any
declaration the DSL can express, `encode` produces what `protoc`-generated code would.
