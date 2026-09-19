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
    { big_number: 1 }
  ].freeze

  REPEATED_CASES = [
    {},
    { r_double: [0.0, 1.5, -0.0], r_int32: [-1, 0, 1], r_sint64: [-1, 1, -(1 << 63)], r_fixed32: [1, 2],
      r_bool: [true, false], r_enum: [:RED, :BLUE, 9], r_string: ["", "a"], r_bytes: ["\x00".b],
      r_message: [{}, { f_int32: 1 }], unpacked: [1, -1] },
    { r_int32: [0] },
    { unpacked: [0] },
    { r_message: [{ child: { f_string: "x" } }] }
  ].freeze

  CHOICE_CASES = [
    {}, { s: "x" }, { s: "" }, { i: -5 }, { i: 0 }, { m: { f_int32: 1 } }, { m: {} }, { c: :GREEN },
    { c: :COLOR_UNSPECIFIED }, { b: "\x01".b }, { b: "".b }, { s: "x", after: "z" }, { after: "only" }
  ].freeze

  MAP_CASES = [
    {}, { ss: { "k" => "v" } }, { ss: { "" => "" } }, { im: { 3 => { f_int32: 1 } } }, { im: { 0 => {} } },
    { si: { "a" => -1 } }, { bs: { true => "t" } }, { bs: { false => "" } }
  ].freeze

  LEGACY_CASES = [
    { must: 1 },
    { must: 1, o_int32: 0, o_string: "", o_default: 42, o_bool: true, o_double: 0.0, o_enum: :FIRST },
    { must: 0, delta: [3, -2, 3], packed_delta: [3, -2, 3], nested: [{ must: 2 }], o_bytes: "\xff".b, o_fixed64: 1 },
    { must: 1, o_enum: :SECOND, o_string: "hello", o_default: 0, o_bool: false }
  ].freeze

  TREE = { label: "root", children: [{ label: "a", children: [{ label: "aa" }] }, { label: "b" }],
           parent: { label: "p" } }.freeze
end
