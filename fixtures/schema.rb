# frozen_string_literal: true

# The parity schemas (fixtures/proto/*.proto) declared with the DSL.
# Every message here has a protoc-generated twin under fixtures/pb with
# the same package, name and field names, so one attributes Hash builds
# both sides.
require "fast/protowire"

module Mirror3
  Color = Fast::Protowire::Enum.define(COLOR_UNSPECIFIED: 0, RED: 1, GREEN: 2, BLUE: 3)

  class Scalars < Fast::Protowire::Message
    field :f_double, :double, 1
    field :f_float, :float, 2
    field :f_int32, :int32, 3
    field :f_int64, :int64, 4
    field :f_uint32, :uint32, 5
    field :f_uint64, :uint64, 6
    field :f_sint32, :sint32, 7
    field :f_sint64, :sint64, 8
    field :f_fixed32, :fixed32, 9
    field :f_fixed64, :fixed64, 10
    field :f_sfixed32, :sfixed32, 11
    field :f_sfixed64, :sfixed64, 12
    field :f_bool, :bool, 13
    field :f_string, :string, 14
    field :f_bytes, :bytes, 15
    field :f_enum, Color, 16
    optional :opt_int32, :int32, 17
    optional :opt_string, :string, 18
    optional :opt_double, :double, 19
    field :child, "Scalars", 20
    field :big_number, :uint32, 536_870_911
  end

  class Repeated < Fast::Protowire::Message
    repeated :r_double, :double, 1
    repeated :r_int32, :int32, 2
    repeated :r_sint64, :sint64, 3
    repeated :r_fixed32, :fixed32, 4
    repeated :r_bool, :bool, 5
    repeated :r_enum, Color, 6
    repeated :r_string, :string, 7
    repeated :r_bytes, :bytes, 8
    repeated :r_message, Scalars, 9
    repeated :unpacked, :int32, 10, packed: false
  end

  class Choice < Fast::Protowire::Message
    oneof :kind do
      field :s, :string, 1
      field :i, :int64, 2
      field :m, Scalars, 3
      field :c, Color, 4
      field :b, :bytes, 5
    end
    field :after, :string, 6
  end

  class Maps < Fast::Protowire::Message
    map :ss, :string, :string, 1
    map :im, :int32, Scalars, 2
    map :si, :string, :int64, 3
    map :bs, :bool, :string, 4
  end

  class Tree < Fast::Protowire::Message
    field :label, :string, 1
    repeated :children, "Tree", 2
    field :parent, "Tree", 3
  end

  class Wide < Fast::Protowire::Message
    field :a, :int32, 1
    field :b, :int32, 2
    field :c, :string, 3
  end

  class Narrow < Fast::Protowire::Message
    field :b, :int32, 2
  end
end

module Mirror2
  Mode = Fast::Protowire::Enum.define(FIRST: 5, SECOND: 6)

  class Legacy < Fast::Protowire::Message
    syntax :proto2
    optional :o_int32, :int32, 1
    optional :o_string, :string, 2, default: "hello"
    optional :o_default, :int32, 3, default: 42
    optional :o_enum, Mode, 4
    optional :o_double, :double, 5
    optional :o_bool, :bool, 6, default: true
    required :must, :int32, 7
    repeated :delta, :sint64, 8
    repeated :packed_delta, :sint64, 9, packed: true
    repeated :nested, "Legacy", 10
    optional :o_bytes, :bytes, 11
    optional :o_fixed64, :fixed64, 12
  end
end
