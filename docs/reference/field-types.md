# Reference: field types

Every scalar type Protocol Buffers defines, as the DSL names it, with its wire type, the
Ruby values it holds, and the rules that decide whether and how it's written.

## Scalars

| Type | Wire type | Ruby value | Range | Default |
|---|---|---|---|---|
| `:double` | 64-bit (1) | `Float` | — | `0.0` |
| `:float` | 32-bit (5) | `Float` | rounded to single precision on assignment | `0.0` |
| `:int32` | varint (0) | `Integer` | −2³¹ ... 2³¹−1; negatives take ten bytes | `0` |
| `:int64` | varint (0) | `Integer` | −2⁶³ ... 2⁶³−1; negatives take ten bytes | `0` |
| `:uint32` | varint (0) | `Integer` | 0 ... 2³²−1 | `0` |
| `:uint64` | varint (0) | `Integer` | 0 ... 2⁶⁴−1 | `0` |
| `:sint32` | varint (0), zigzag | `Integer` | −2³¹ ... 2³¹−1 | `0` |
| `:sint64` | varint (0), zigzag | `Integer` | −2⁶³ ... 2⁶³−1 | `0` |
| `:fixed32` | 32-bit (5) | `Integer` | 0 ... 2³²−1 | `0` |
| `:fixed64` | 64-bit (1) | `Integer` | 0 ... 2⁶⁴−1 | `0` |
| `:sfixed32` | 32-bit (5) | `Integer` | −2³¹ ... 2³¹−1 | `0` |
| `:sfixed64` | 64-bit (1) | `Integer` | −2⁶³ ... 2⁶³−1 | `0` |
| `:bool` | varint (0) | `true` / `false` | — | `false` |
| `:string` | length-delimited (2) | `String`, UTF-8 | must be valid UTF-8 | `""` |
| `:bytes` | length-delimited (2) | `String`, binary | — | `"".b` |
| an `Enum` module | varint (0) | `Symbol` for declared values, `Integer` otherwise | int32 | value 0, else first declared |
| a `Message` class | length-delimited (2) | instance | — | `nil` |

Integers are validated on assignment: a non-integral `Numeric` or a value outside the range
raises `RangeError`. Floats accept any `Numeric` and store `to_f`, except that a `:float`
stores what the wire will carry, the value narrowed to single precision, as the reference
narrows it: `f_float = 0.1` reads back `0.10000000149011612`, `3.5e38` reads `Infinity`,
`1e-50` reads `0.0` and so isn't written at all. `decode(encode(m)) == m` follows from that.
One exception is not covered: a 32-bit `float` NaN is written canonical (`7fc00000`), since
Ruby's `pack("e")` drops the sign and payload bits the reference preserves. `double` NaNs
round-trip whole.

On decode a varint carrying more bits than the field holds is truncated to the field's
width, as every implementation does: `uint64`/`sint64`/`int64` to 64 bits,
`int32`/`uint32`/`sint32`/enums to 32 before their sign or zigzag mapping is undone. A
`string` field is tagged UTF-8 and, under proto3, must be valid UTF-8 or the decode raises
`DecodeError`; proto2 keeps the bytes, as the reference does. A `bytes` field is binary,
whatever the input String was tagged.

## Presence

Whether a set field is written depends on its rule:

| Rule | Written when |
|---|---|
| `field` under proto3 | The value is not the default. Strings and bytes when non-empty, bools when `true`, enums when non-zero, integers when non-zero, floats when their bits are non-zero (`-0.0` is written; `0.0` is not), messages whenever set (an empty message is written as a zero-length field). |
| `field` under proto2, `optional`, `required`, any oneof member | Whenever set, including when set to the default. |
| `repeated` | When non-empty. |
| `map` | When non-empty, one length-delimited entry per pair, in insertion order. Each entry writes its key (field 1) and value (field 2) whether or not they're defaults. An entry that arrives without one of them decodes to that type's default — an empty message for a message-typed value. An entry that arrives with more than those two is kept out of the map, as an unknown field of the message; see [How encoding works](../explanation/encoding.md#decoding). |

## Packing

A `repeated` field of a packable type (every scalar except `:string` and `:bytes`; enums
included) is either packed, one length-delimited field holding all values back to back, or
unpacked, one tagged value per element. proto3 packs by default; proto2 does not.
`packed:` overrides either — except that `packed: true` on a type that can't pack (`:string`,
`:bytes`, a message) is a declaration the wire format has no form for, so it raises
`ArgumentError` where it's written rather than at the first `encode`. Decoding accepts both
forms regardless of the declaration, as the specification requires. Any other wire type on a
declared field is schema drift: the field is kept as an unknown one and re-encoded verbatim,
not raised on.

## Enums

```ruby
Color = Fast::Protowire::Enum.define(RED: 1, GREEN: 2)
```

| Signature | Returns | Notes |
|---|---|---|
| `Enum.define(**values)` | `Module` | One constant per name; the module extends `Enum`. |
| `Color::RED` | `Integer` | |
| `Color.lookup(number)` | `Symbol` or `nil` | |
| `Color.resolve(name)` | `Integer` or `nil` | |
| `Color.values` | `Hash{Symbol => Integer}` | Frozen, in declaration order. |
| `Color.default` | `Symbol` | The name for 0 if declared, else the first declared name. |

A field of this type stores the Symbol for a declared value and the `Integer` for any
other in-range value, on assignment and on decode alike.
