# Reference: Message

`Fast::Protowire::Message` is the base class for declared messages. A subclass describes
its fields with the class-level DSL and gains the instance API below.

## Class-level DSL

Every declaration takes the field's `name` (a Symbol), its `type`, and its `number`.
`type` is a scalar Symbol (see [Reference: field types](field-types.md)), an `Enum`
module, a `Message` subclass, or a String naming a `Message` subclass in the declaring
class's namespace, resolved on first use.

| Signature | Rule | Notes |
|---|---|---|
| `syntax(:proto2 \| :proto3)` | — | Sets the file syntax the class follows; default `:proto3`. Affects `field` and the default packing of `repeated` scalars. Raises `ArgumentError` for anything else. |
| `field(name, type, number, default: nil)` | implicit presence under proto3; `optional` under proto2 | Omitted from the output when the value is its default. A message-typed `field` always has presence. |
| `optional(name, type, number, default: nil)` | explicit presence | Written whenever set, even to the default. Adds `has_name?` and `clear_name`. `default:` is the proto2 declared default returned while unset. |
| `required(name, type, number, default: nil)` | explicit presence | Same as `optional`; nothing enforces presence on encode, matching `google-protobuf`. |
| `repeated(name, type, number, packed: nil)` | repeated | Holds an Array. Packable scalars pack by default under proto3 and not under proto2; `packed:` overrides. Strings, bytes and messages never pack. |
| `map(name, key_type, value_type, number)` | map | Holds a Hash. `key_type` is any integer type, `:bool` or `:string`; `value_type` is any type. Raises `ArgumentError` for other key types. |
| `oneof(name) { ... }` | — | Fields declared in the block are members. Setting one clears the others; every member has presence (`has_x?`). Adds a `name` reader returning the Symbol of the set member, or `nil`. Oneofs don't nest. |

Declaring a duplicate name or number raises `ArgumentError`.

Class methods

| Signature | Returns | Notes |
|---|---|---|
| `.new(attributes = nil, **keywords)` | instance | Takes a Hash (String or Symbol keys) or keywords. Nested Hashes build message-typed fields; Arrays fill repeated fields; Hashes fill maps; Symbols or Integers set enums. Raises `ArgumentError` for an unknown name and `TypeError`/`RangeError` for a value the field can't hold. |
| `.decode(bytes)` | instance | Parses `bytes` (a binary String). Later scalars win, repeated fields append, nested messages merge, packed and unpacked repeated scalars are both accepted, unknown fields are kept. Raises `DecodeError` on truncated input, an unknown wire type, or a known field with the wrong wire type. |
| `.encode(message)` | `String` | Same as `message.encode`. |
| `.fields` | `Hash{Symbol => Field}` | Declared fields in declaration order. |
| `.fields_by_number` | `Hash{Integer => Field}` | |
| `.oneofs` | `Hash{Symbol => Array<Symbol>}` | Members per oneof. |
| `.sorted_fields` | `Array<Field>` | By field number, the order fields are written. |
| `.syntax` | `:proto2 \| :proto3` | |
| `.compile_encoder` | — | Defines the class's own `#encode` from one closure per field (`Field#encoder_step`). Called for you on the first `encode`; a later declaration discards it so the next `encode` recompiles. |

## Instance API

Per field, the class defines `name` and `name=`. A reader returns the field's default while
the field is unset: `0`, `0.0`, `""`, `"".b`, `false`, the enum's default (the value for 0,
else the first declared), `[]` for repeated, `{}` for maps, and `nil` for a message-typed
field. Fields with presence also get `has_name?` and `clear_name`.

Assignment validates: strings must be `String` and valid UTF-8 (`ArgumentError` otherwise;
non-UTF-8 encodings are transcoded), bytes must be `String` (kept as binary), integers must
be integral `Numeric` within the type's range (`RangeError` otherwise), floats any
`Numeric`, bools `true`/`false`, enums a declared Symbol or an int32 `Integer` (unknown
Integers are kept as Integers), messages an instance of the class or a Hash to build one.
`nil` clears a field with presence.

| Signature | Returns | Notes |
|---|---|---|
| `encode(buffer = String.new)` | `buffer` | Appends the message's bytes to `buffer` and returns it. Fields are written in number order, then any unknown fields. |
| `to_proto(buffer = String.new)` | `buffer` | Same as `encode`; the name `protocol-grpc` and `google-protobuf` callers look for. |
| `merge_from(reader)` | `self` | Reads fields from a `Reader` into this message with the merge semantics of `.decode`. |
| `to_h` | `Hash{Symbol => Object}` | Fields with presence appear only when set; others always, with their default. Nested messages become Hashes recursively; enums stay Symbols. |
| `==(other)` / `eql?` | `Boolean` | Same class, every field reads the same (an implicit field set to its default equals an unset one), same unknown fields. |
| `hash` | `Integer` | Consistent with `==`. |
| `dup` / `clone` | copy | Deep: nested messages, Arrays, Hashes and Strings are copied. |
| `unknown_fields` | `String` or `nil` | Raw tag-and-value bytes of fields the class doesn't declare, from the last decode. |
| `inspect` | `String` | `#<ClassName name: value, ...>` listing set fields. |

## Errors

| Class | Raised when |
|---|---|
| `Fast::Protowire::DecodeError` (`< Fast::Protowire::Error < StandardError`) | Input doesn't parse: truncated varint or field, unknown wire type, wrong wire type for a declared field, malformed group. |
| `::TypeError` | A value of the wrong Ruby type is assigned. |
| `::RangeError` | An integer out of the type's range, a non-integral number for an integer field, or an undeclared enum Symbol. |
| `::ArgumentError` | An unknown field name on construction, invalid UTF-8 for a string field, or an invalid declaration. |
