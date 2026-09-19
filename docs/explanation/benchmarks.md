# Benchmarks

What declared messages cost: fast-protowire 0.3.0 measured against `google-protobuf`
4.36.2 on the same schema and the same bytes, and what changed since 0.1.0. Single
process, Ruby 4.0.7, Apple M4 Max (arm64-darwin). `benchmark/messages.rb` produces every
table below; timed columns are the mean of ten calls with GC on, allocation columns are one
call with GC off, so they are the call's whole footprint: Ruby objects (`GC.stat`), bytes
malloc'd, and the native arenas `google-protobuf` leaves alive.

The schema is the Prometheus client model (`fixtures/proto/metrics.proto`, upstream
`client_model`), and the shape is a production scrape: one `MetricFamily` of 36,000
`Metric`s, each with twelve `LabelPair`s and a `Counter`, 11.76 MB on the wire.

Read the two libraries for what they are. `google-protobuf` is a binding over `upb`, a C
runtime: once a message tree exists natively, encoding and decoding it are native, and a
nested Hash is converted to one natively too. fast-protowire is plain Ruby, one object per
message with an instance variable per field, and its encoder and decoder are Ruby method
calls. Where the two differ is memory: what each message costs to exist, what a build or a
decode leaves behind, and what the garbage collector then has to do about it.

## Since 0.1.0

The same family, encoded, built-then-encoded, and decoded, on 0.1.0 and on this version
(`benchmark/since.rb`: 5 timed calls with GC on; objects are one call):

| operation | 0.1.0 | now |
|---|---|---|
| encode | 0.312 s, 647,240 objects | 0.303 s, 2 objects |
| build from a Hash, encode | 0.644 s, 1,727,244 objects | 0.644 s, 576,004 objects |
| decode | 1.311 s, 7,128,016 objects | 0.801 s, 1,404,005 objects |

Encoding allocated a String per nested message plus a binary copy of it whenever it held a
byte over 127 (every `Counter`, every `Metric`), and an Array per `double`. It now writes
every nested message, packed field and map entry straight into the parent buffer behind a
length prefix filled in afterwards, packs with literal formats and appends text as bytes;
see [How encoding works](encoding.md#buffers). Decoding allocated an Array per tag, a String
and a `Reader` per nested message, an empty keyword Hash per `Message.new`, and one object
per `read_varint` (a `Kernel#loop` block). It now reads in place; what remains is the
messages, their containers and their Strings. `test/fast/protowire/allocations.rb` holds
these budgets on every supported Ruby.

0.3.0 checks every field's wire type, rejects field number 0 and counts the nesting on
every field of every nested message, and decodes the family in 0.801 s where 0.2.0 takes
0.784 s in the same session: a field's wire type is computed once, when it is declared,
rather than on every read, which pays for the checks. What a decode allocates did not move.

## Encode, by shape

The same attributes built on both sides and encoded to the same bytes:

| shape | library | bytes | ms/call | objects/call | malloc MiB/call | live arenas after | GC runs (10 calls) | GC ms |
|---|---|---|---|---|---|---|---|---|
| MetricFamily, 36,000 metrics x 12 labels | fast-protowire | 11.76 MB | 295.544 | 3 | 16.0 | 0 | 2 minor + 1 major | 46 |
| MetricFamily, 36,000 metrics x 12 labels | google-protobuf | 11.76 MB | 12.047 | 2 | 11.2 | 0 | 2 minor + 1 major | 46 |
| Scalars, every type | fast-protowire | 0.0 MB | 0.012 | 16 | 0.0 | 0 | 0 minor + 0 major | 0 |
| Scalars, every type | google-protobuf | 0.0 MB | 0.001 | 2 | 0.0 | 0 | 0 minor + 0 major | 0 |
| Repeated, 10,000 packed doubles + int32s | fast-protowire | 0.1 MB | 1.793 | 1 | 0.1 | 0 | 0 minor + 0 major | 0 |
| Repeated, 10,000 packed doubles + int32s | google-protobuf | 0.1 MB | 0.019 | 2 | 0.1 | 0 | 0 minor + 0 major | 0 |
| Maps, 10,000 string entries | fast-protowire | 0.24 MB | 3.176 | 1 | 0.3 | 0 | 0 minor + 0 major | 0 |
| Maps, 10,000 string entries | google-protobuf | 0.24 MB | 0.139 | 2 | 0.2 | 0 | 0 minor + 0 major | 0 |
| Tree, depth 3 | fast-protowire | 0.0 MB | 0.005 | 1 | 0.0 | 0 | 0 minor + 0 major | 0 |
| Tree, depth 3 | google-protobuf | 0.0 MB | 0.001 | 2 | 0.0 | 0 | 0 minor + 0 major | 0 |

Encoding an existing tree allocates one object here, the output, whatever the shape or
size (the `Scalars` case carries 64-bit extremes whose arithmetic makes Bignums). It is
also 25x slower than `upb` walking its arena in C: a Ruby method call per field is the
floor of this design. Map entries come out in each library's own order; the parity suite
checks the bytes are otherwise identical.

## Build, encode, discard

A family made from scratch and encoded once, the way an exposition or a request body is
produced. Two ways to make it: from one nested Hash, which `google-protobuf` converts to
its arena natively, and a message at a time from live values, which is what code that
builds series as it goes does:

| library | ms/call | objects/call | malloc MiB/call | live arenas after | GC runs (10 calls) | GC ms |
|---|---|---|---|---|---|---|
| fast-protowire, from one Hash | 614.413 | 576,005 | 16.3 | 0 | 2 minor + 1 major | 58 |
| google-protobuf, from one Hash | 69.376 | 6 | 54.3 | 1 | 12 minor + 2 major | 73 |
| fast-protowire, a message at a time | 729.96 | 2,987,902 | 16.5 | 0 | 6 minor + 0 major | 266 |
| google-protobuf, a message at a time | 514.097 | 3,923,902 | 224.6 | 504,001 | 37 minor + 9 major | 1766 |

Read the object and malloc columns together, because the two libraries put the same work
in different places. From one Hash, `google-protobuf` hands the whole Hash to `upb`, which
builds native structs inside one arena and creates no Ruby wrapper for any of the 504,000
messages in it (wrappers appear lazily, as fields are read), so Ruby sees six objects and
the cost lands in the malloc column: 54 MiB of native memory for an 11.76 MB body, 3.3x
what fast-protowire mallocs for the same, and 8.9x faster. fast-protowire's 576,005 objects
*are* the family: 36,000 `Metric`s, 432,000 `LabelPair`s, 36,000 `Counter`s and their label
Arrays, ordinary small Ruby objects that come and go with a minor GC (58 ms of GC per ten
builds against 73). A message at a time is the pattern that made this gem: every `LabelPair.new` is a
native arena plus a Ruby wrapper registered in a process-wide object cache, so 36,000
metrics leave 504,001 arenas and 225 MiB behind, and the collector spends 1.77 s of the ten
calls on them. fast-protowire's messages are ordinary objects, 16.5 MiB in total, 0.27 s
of GC. (The million extra objects on both sides are the label Strings and keyword Hashes
the builder itself makes.)

fast-prometheus's exposition goes one step further and builds no message per series at
all: it writes series bytes with `Wire` directly, which is why its
[scrape benchmarks](https://github.com/jetpks/fast-prometheus/blob/main/docs/explanation/benchmarks.md)
render 36,000 series in 29 objects and 0.18 s.

## Decode

The family's bytes back into messages, and then read through, every label's value once:

| library | ms/call | objects/call | malloc MiB/call | live arenas after | GC runs (10 calls) | GC ms |
|---|---|---|---|---|---|---|
| fast-protowire, decode | 785.399 | 1,404,006 | 5.7 | 0 | 2 minor + 0 major | 67 |
| google-protobuf, decode | 13.249 | 4 | 43.1 | 1 | 12 minor + 0 major | 30 |
| fast-protowire, decode and read every label | 807.468 | 1,404,009 | 5.7 | 0 | 2 minor + 0 major | 86 |
| google-protobuf, decode and read every label | 225.627 | 1,404,012 | 74.9 | 1 | 11 minor + 0 major | 349 |

`google-protobuf` decodes lazily: 13 ms parses the body into an arena, and Ruby objects
appear as fields are read. Read every label and it is 226 ms, the same 1.4 million objects
fast-protowire made up front, and 75 MiB against 5.7. fast-protowire's decode is eager and
3.6x slower for the read-through case; it allocates exactly the messages, containers and
Strings it hands back.

## By size

| metrics | bytes | fast encode ms | objects | google encode ms | objects | fast decode ms | google decode ms |
|---|---|---|---|---|---|---|---|
| 1,000 | 0.32 MB | 7.645 | 1 | 0.181 | 2 | 22.094 | 0.297 |
| 10,000 | 3.18 MB | 78.525 | 1 | 1.883 | 2 | 215.138 | 3.576 |
| 36,000 | 11.76 MB | 279.422 | 1 | 7.41 | 2 | 785.123 | 14.576 |
| 100,000 | 32.88 MB | 776.899 | 1 | 20.499 | 2 | 2185.772 | 93.183 |

Every column is linear in the number of metrics, and encoding allocates one object at
every size. The length-prefix hint (see [Buffers](encoding.md#buffers)) is what keeps the
32.88 MB case linear: without it, each `Metric`'s prefix resize reallocated the whole
buffer.

## Per message

`benchmark-ips` over one `LabelPair` and one twelve-label `Metric`, 2 s per row after 1 s
of warmup; objects per call are `GC.stat`, exact:

| operation | fast-protowire i/s | google-protobuf i/s | fast / google | fast-protowire objects/call | google-protobuf objects/call |
|---|---|---|---|---|---|
| LabelPair encode | 2.56M | 8.11M | 0.32x | 1.0 | 2.0 |
| Metric encode (12 labels) | 0.13M | 2.41M | 0.05x | 1.0 | 2.0 |
| LabelPair decode | 0.94M | 2.26M | 0.41x | 4.0 | 3.0 |
| Metric decode (12 labels) | 0.05M | 1.07M | 0.04x | 40.0 | 3.0 |
| Metric build from Hash + encode | 0.06M | 0.41M | 0.15x | 17.0 | 5.0 |

## Reproducing

```bash
BENCH_QUICK=1 bundle exec ruby benchmark/messages.rb   # 5,000 metrics, about a minute
bundle exec ruby benchmark/messages.rb                 # 36,000 metrics, about ten minutes
METRICS=n bundle exec ruby benchmark/messages.rb       # pick the main size
bundle exec ruby benchmark/since.rb                    # the Since 0.1.0 rows, about a minute
```

## Key takeaways

- Encoding a declared message allocates **one object, its output**, at any size and depth;
  0.1.0 allocated one per nested message and one per `double`, 647,000 for this family.
- Decoding allocates only what it returns: **5x fewer objects** than 0.1.0 and 1.6x faster,
  with 0.3.0's wire-type, field-number and depth checks on every field.
- `google-protobuf` is **9 to 25x faster** per operation on an existing tree or a single
  Hash; it is native. Choose it when speed per message is the constraint and a native
  arena per message is acceptable.
- Ruby object counts do not see native memory. `google-protobuf` building from one Hash
  shows six objects and **54 MiB of arena**; fast-protowire shows 576,005 objects and
  16 MiB. The objects are the messages, and they are cheap; the arena is what the
  collector cannot reclaim until every wrapper into it is gone.
- Built a message at a time, `google-protobuf` costs **225 MiB and 504,001 native arenas**
  for an 11.76 MB body and 1.77 s of GC per ten builds; fast-protowire costs 16.5 MiB, no
  arenas, and 0.27 s. That is the case this gem exists for.
- Decoded and read, `google-protobuf` mallocs **13x more** for the same objects.
