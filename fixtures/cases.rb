# frozen_string_literal: true

# Attribute sets the parity suite builds on both sides. Each Hash is valid
# input for the protoc-generated class and for its DSL mirror alike.
module ParityCases
  SCALAR_CASES = [
    {},
    { f_double: 1.5, f_float: -2.25, f_int32: -1, f_int64: -(1 << 63), f_uint32: (1 << 32) - 1, f_uint64: (1 << 64) - 1,
      f_sint32: -(1 << 31), f_sint64: (1 << 63) - 1, f_fixed32: 7, f_fixed64: 1 << 40, f_sfixed32: -7,
      f_sfixed64: -(1 << 40), f_bool: true, f_string: "héllo ✓", f_bytes: "\x00\xff\x01".b, f_enum: :BLUE,
      opt_int32: 0, opt_string: "", opt_double: 0.0, child: { f_int32: 5, child: { f_string: "deep" } },
      big_number: 9 },
    { f_double: -0.0 },
    { f_float: -0.0 },
    { f_double: Float::INFINITY, f_float: -Float::INFINITY },
    { f_int32: (1 << 31) - 1, f_int64: (1 << 63) - 1 },
    { f_int32: -(1 << 31), f_sint32: (1 << 31) - 1 },
    { f_int64: 300, f_uint32: 300, f_sint64: -300 },
    { f_enum: 7 },
    { f_enum: :RED },
    { f_string: "", f_bool: false, f_bytes: "".b, f_double: 0.0 },
    { child: {} },
    { opt_int32: 0 },
    { opt_string: "" },
    { opt_double: -0.0 },
    { big_number: 1 },
    # Non-ASCII text and high bytes inside nested messages, and nested
    # messages long enough for two- and three-byte length prefixes.
    { f_string: "héllo ✓", child: { f_string: "ünïcödé", f_bytes: "\xff\x80".b, child: { f_string: "✓" } } },
    { f_string: "x" * 200, child: { f_string: "y" * 20_000, child: { f_bytes: ("\xff" * 130).b } } }
  ].freeze

  REPEATED_CASES = [
    {},
    { r_double: [0.0, 1.5, -0.0], r_int32: [-1, 0, 1], r_sint64: [-1, 1, -(1 << 63)], r_fixed32: [1, 2],
      r_bool: [true, false], r_enum: [:RED, :BLUE, 9], r_string: ["", "a"], r_bytes: ["\x00".b],
      r_message: [{}, { f_int32: 1 }], unpacked: [1, -1] },
    { r_int32: [0] },
    { unpacked: [0] },
    { r_message: [{ child: { f_string: "x" } }] },
    # Entries whose length prefixes alternate between one and two bytes.
    { r_message: [{ f_string: "x" * 200 }, {}, { f_string: "x" * 200 }, { f_string: "é" }], r_string: ["é", "x" * 300],
      r_bytes: ["\xff".b], r_double: Array.new(40) { |i| i * 0.5 } }
  ].freeze

  CHOICE_CASES = [
    {}, { s: "x" }, { s: "" }, { i: -5 }, { i: 0 }, { m: { f_int32: 1 } }, { m: {} }, { c: :GREEN },
    { c: :COLOR_UNSPECIFIED }, { b: "\x01".b }, { b: "".b }, { s: "x", after: "z" }, { after: "only" }
  ].freeze

  MAP_CASES = [
    {}, { ss: { "k" => "v" } }, { ss: { "" => "" } }, { im: { 3 => { f_int32: 1 } } }, { im: { 0 => {} } },
    { si: { "a" => -1 } }, { bs: { true => "t" } }, { bs: { false => "" } },
    { ss: { "ké" => "vé" } }, { ss: { "long" => "z" * 500 } }, { im: { 2 => { f_string: "x" * 200 } } }
  ].freeze

  # Maps with several entries encode equivalently, not identically: the
  # reference orders entries its own way. Entries here alternate between
  # one- and two-byte length prefixes.
  MULTI_MAP_CASES = [
    { ss: { "b" => "2", "a" => "1" }, si: { "x" => 1, "y" => 2 } },
    { ss: { "ké" => "vé", "long" => "z" * 500, "k" => "v" } },
    { im: { 1 => { f_string: "é" }, 2 => { f_string: "x" * 200 }, 3 => {} } }
  ].freeze

  # Families the way an exposition builds them: every metric type, labels,
  # an exemplar with its timestamp, native-histogram spans, and a wide
  # family whose Metric entries take two-byte length prefixes.
  PROMETHEUS_CASES = [
    { name: "http_requests_total", help: "requests", type: :COUNTER,
      metric: [{ label: [{ name: "method", value: "GET" }, { name: "code", value: "200" }],
                 counter: { value: 1027.0 } },
               { label: [{ name: "method", value: "POST" }, { name: "code", value: "500" }],
                 counter: { value: 3.0, exemplar: { label: [{ name: "trace_id", value: "abc" }], value: 1.0,
                                                    timestamp: { seconds: 1_700_000_000, nanos: 5 } } },
                 timestamp_ms: 1_700_000_000_123 }] },
    { name: "temperature", type: :GAUGE, unit: "celsius",
      metric: [{ label: [{ name: "room", value: "kitchen" }], gauge: { value: -0.5 } }] },
    { name: "request_seconds", type: :HISTOGRAM,
      metric: [{ histogram: { sample_count: 3, sample_sum: 0.75,
                              bucket: [{ cumulative_count: 1, upper_bound: 0.1 },
                                       { cumulative_count: 3, upper_bound: 0.5 },
                                       { cumulative_count: 3, upper_bound: Float::INFINITY }],
                              schema: 3, zero_threshold: 1e-128, zero_count: 1,
                              positive_span: [{ offset: 1, length: 2 }], positive_delta: [3, -2],
                              negative_span: [{ offset: -1, length: 1 }], negative_delta: [1] } }] },
    { name: "payload_bytes", type: :SUMMARY,
      metric: [{ summary: { sample_count: 2, sample_sum: 512.0,
                            quantile: [{ quantile: 0.5, value: 200.0 }, { quantile: 0.99, value: 312.0 }] } }] },
    { name: "wide", type: :COUNTER,
      metric: Array.new(40) do |i|
        { label: Array.new(4) { |l| { name: "label_#{l}", value: "value_#{l}_#{i}" } }, counter: { value: i * 0.25 } }
      end }
  ].freeze

  LEGACY_CASES = [
    { must: 1 },
    { must: 1, o_int32: 0, o_string: "", o_default: 42, o_bool: true, o_double: 0.0, o_enum: :FIRST },
    { must: 0, delta: [3, -2, 3], packed_delta: [3, -2, 3], nested: [{ must: 2 }], o_bytes: "\xff".b, o_fixed64: 1 },
    { must: 1, o_enum: :SECOND, o_string: "hello", o_default: 0, o_bool: false }
  ].freeze

  # Bytes no encoder here produces but a decoder meets: varints wider than the
  # field, a declared field arriving with a wire type it does not accept, a map
  # entry that omits its value. Both sides decode each and must agree on the
  # value and on the bytes it re-encodes to.
  SCALARS_DECODE_CASES = {
    "uint64 in ten bytes, tenth 0x7f" => "\x30#{"\xff" * 9}\x7f",
    "uint64 in ten bytes, tenth 0x02" => "\x30#{"\x80" * 9}\x02",
    "sint32 with bits above 32" => "\x38\x83\x80\x80\x80\x80\x20",
    "sint64 in ten bytes, tenth 0x7f" => "\x40#{"\xff" * 9}\x7f",
    "string field as a varint" => "\x70\x01\x18\x05",
    "int32 field length-delimited" => "\x1a\x01\x78\x18\x05",
    "message field as fixed32" => "\xa5\x01\x01\x02\x03\x04\x18\x05",
    "unknown field in a child" => "\xa2\x01\x05\x9a\x06\x02\xc3\xa9\xf8\xff\xff\xff\x0f\x09"
  }.transform_values { |bytes| bytes.b.freeze }.freeze

  MAPS_DECODE_CASES = {
    "map entry holding only its key" => "\x12\x02\x08\x07",
    "empty map entry" => "\x12\x00"
  }.transform_values { |bytes| bytes.b.freeze }.freeze

  TREE = { label: "root", children: [{ label: "a", children: [{ label: "aa" }] }, { label: "b" }],
           parent: { label: "p" } }.freeze
end
