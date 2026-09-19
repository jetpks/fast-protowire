# AGENTS.md

Standing context for agents working in this repository.

## Commands

```bash
bundle install
bundle exec sus
bundle exec rubocop
bundle exec ruby benchmark/messages.rb   # encode, build and decode against google-protobuf; BENCH_QUICK=1 for a short run
protoc --proto_path=fixtures/proto --proto_path=/opt/homebrew/include --ruby_out=fixtures/pb fixtures/proto/*.proto
# regenerates the reference schemas; the second path is where protoc keeps google/protobuf/timestamp.proto
```

## What this is

The Protocol Buffers wire format, and nothing above it: a `Wire` writer, a
`Reader`, and a `Message` DSL that declares fields and derives encode/decode
from the declaration. No descriptors, reflection, JSON mapping or generated
code. `google-protobuf` is a development dependency only — the parity suite
(`test/fast/protowire/parity.rb`) encodes the same attributes with both and
requires identical bytes.

## Style Rules

- 2-space indentation, `# frozen_string_literal: true` on every source file, double-quoted strings
- No runtime dependencies. If a feature needs one, it does not belong here.
- Encoded bytes must match the reference implementation for every case the
  DSL can express; add a parity case before changing encoding behavior.

## Test Rules

- `sus`; tests are terse and exercise public interfaces only
- No mock/stub of the class under test
- Schemas used by tests live in `fixtures/proto` (source of truth), `fixtures/pb`
  (protoc output, checked in) and `fixtures/schema.rb` (the DSL mirror)
