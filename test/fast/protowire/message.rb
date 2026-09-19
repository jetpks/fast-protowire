# frozen_string_literal: true

require "fast/protowire"
require "schema"

describe Fast::Protowire::Message do
  # +depth+ message wrappers, under field +number+ (Tree.parent by default),
  # around +inner+.
  def nested(depth, number = 3, inner = "".b)
    tag = Fast::Protowire::Wire.tag(number, Fast::Protowire::Wire::LENGTH_DELIMITED)
    depth.times.inject(inner) { |bytes, _| tag + Fast::Protowire::Wire.varint(bytes.bytesize) + bytes }
  end

  it "reads defaults for unset fields and reports presence only where the schema has it" do
    scalars = Mirror3::Scalars.new
    expect(scalars.f_int32).to be(:==, 0)
    expect(scalars.f_string).to be(:==, "")
    expect(scalars.f_enum).to be(:==, :COLOR_UNSPECIFIED)
    expect(scalars.child).to be_nil
    expect(scalars.opt_int32).to be(:==, 0)
    expect(scalars).not.to be(:has_opt_int32?)
    expect(scalars).not.to be(:respond_to?, :has_f_int32?)
    scalars.opt_int32 = 0
    expect(scalars).to be(:has_opt_int32?)
    scalars.clear_opt_int32
    expect(scalars).not.to be(:has_opt_int32?)
  end

  it "applies proto2 declared defaults" do
    legacy = Mirror2::Legacy.new
    expect(legacy.o_string).to be(:==, "hello")
    expect(legacy.o_default).to be(:==, 42)
    expect(legacy.o_bool).to be(:==, true)
    expect(legacy.o_enum).to be(:==, :FIRST)
    expect(legacy.encode).to be(:==, "")
  end

  it "keeps one member of a oneof set at a time" do
    choice = Mirror3::Choice.new(s: "x")
    expect(choice.kind).to be(:==, :s)
    choice.i = 3
    expect(choice.kind).to be(:==, :i)
    expect(choice).not.to be(:has_s?)
    expect(choice.s).to be(:==, "")
    expect(Mirror3::Choice.new.kind).to be_nil
  end

  it "coerces nested hashes, arrays and enum names on construction" do
    tree = Mirror3::Tree.new(label: "root", children: [{ label: "a" }, Mirror3::Tree.new(label: "b")],
                             parent: { label: "p" })
    expect(tree.children.map(&:label)).to be(:==, %w[a b])
    expect(tree.parent.label).to be(:==, "p")
    expect(Mirror3::Scalars.new("f_enum" => 2).f_enum).to be(:==, :GREEN)
    expect(Mirror3::Scalars.new(f_enum: 9).f_enum).to be(:==, 9)
  end

  it "rejects values the field cannot hold" do
    expect { Mirror3::Scalars.new(f_string: 1) }.to raise_exception(::TypeError)
    expect { Mirror3::Scalars.new(f_int32: 1 << 31) }.to raise_exception(::RangeError)
    expect { Mirror3::Scalars.new(f_uint32: -1) }.to raise_exception(::RangeError)
    expect { Mirror3::Scalars.new(f_int32: 1.5) }.to raise_exception(::RangeError)
    expect { Mirror3::Scalars.new(f_enum: :PURPLE) }.to raise_exception(::RangeError)
    expect { Mirror3::Scalars.new(f_bool: 1) }.to raise_exception(::TypeError)
    expect { Mirror3::Scalars.new(f_string: "\xff".b) }.to raise_exception(::ArgumentError)
    expect { Mirror3::Scalars.new(child: 1) }.to raise_exception(::TypeError)
    expect { Mirror3::Repeated.new(r_int32: 1) }.to raise_exception(::TypeError)
    expect { Mirror3::Scalars.new(nope: 1) }.to raise_exception(::ArgumentError)
  end

  it "compares, hashes, copies deeply and converts to Hash" do
    a = Mirror3::Tree.new(label: "root", children: [{ label: "a" }])
    b = Mirror3::Tree.new(label: "root", children: [{ label: "a" }])
    expect(a).to be(:==, b)
    expect(a.hash).to be(:==, b.hash)
    copy = a.dup
    copy.children.first.label = "changed"
    expect(a.children.first.label).to be(:==, "a")
    expect(a.to_h).to be(:==, { label: "root", children: [{ label: "a", children: [] }] })
    expect(Mirror3::Choice.new(i: 1).to_h).to be(:==, { i: 1, after: "" })
    expect(a.inspect).to be(:==, '#<Mirror3::Tree label: "root", children: [#<Mirror3::Tree label: "a">]>')
  end

  it "appends to a caller's buffer, and takes attributes as a Hash or as keywords" do
    scalars = Mirror3::Scalars.new(f_int32: 1)
    buffer = "prefix".b
    expect(scalars.encode(buffer)).to be(:equal?, buffer)
    expect(buffer).to be(:==, "prefix\x18\x01".b)
    expect(Mirror3::Scalars.new({ f_int32: 1 })).to be(:==, scalars)
    expect(Mirror3::Scalars.new).to be(:==, Mirror3::Scalars.new({}))
  end

  it "accepts packed and unpacked encodings of any repeated scalar" do
    unpacked = "\x10\x01\x10\x02".b # r_int32 (2) as two varints
    expect(Mirror3::Repeated.decode(unpacked).r_int32).to be(:==, [1, 2])
    packed = "\x52\x0b\x01\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01".b # unpacked (10) sent packed
    expect(Mirror3::Repeated.decode(packed).unpacked).to be(:==, [1, -1])
  end

  it "merges when a message is decoded from concatenated encodings" do
    first = Mirror3::Scalars.new(f_int32: 1, f_string: "old", child: { f_int32: 1 }).encode
    second = Mirror3::Scalars.new(f_string: "new", child: { f_string: "c" }).encode
    merged = Mirror3::Scalars.decode(first + second)
    expect(merged.f_int32).to be(:==, 1)
    expect(merged.f_string).to be(:==, "new")
    expect(merged.child.f_int32).to be(:==, 1)
    expect(merged.child.f_string).to be(:==, "c")
    halves = [Mirror3::Repeated.new(r_int32: [1]), Mirror3::Repeated.new(r_int32: [2])].map(&:encode)
    repeated = Mirror3::Repeated.decode(halves.join)
    expect(repeated.r_int32).to be(:==, [1, 2])
  end

  it "compares and hashes declared fields only, unknown ones aside" do
    with_unknown = Mirror3::Narrow.decode(Mirror3::Wide.new(a: 1, b: 2, c: "x").encode)
    plain = Mirror3::Narrow.new(b: 2)
    expect(with_unknown).to be(:==, plain)
    expect(with_unknown.hash).to be(:==, plain.hash)
    expect({ plain => :found }[with_unknown]).to be(:==, :found)
    expect(with_unknown.unknown_fields).to be(:==, Mirror3::Wide.new(a: 1, c: "x").encode)
    expect(with_unknown.encode).not.to be(:==, plain.encode)
    expect(Mirror3::Narrow.new(b: 3)).not.to be(:==, plain)
  end

  it "stores a float field at single precision, as the wire carries it" do
    scalars = Mirror3::Scalars.new(f_float: 0.1)
    expect(scalars.f_float).to be(:==, 0.10000000149011612)
    expect(Mirror3::Scalars.decode(scalars.encode)).to be(:==, scalars)
    expect(Mirror3::Scalars.new(f_float: 3.5e38).f_float).to be(:==, Float::INFINITY)
    expect(Mirror3::Scalars.new(f_float: 1e-50).encode).to be(:==, "".b) # underflows to 0.0, so unwritten
    expect(Mirror3::Scalars.new(f_double: 0.1).f_double).to be(:==, 0.1)
  end

  it "keeps a known field arriving with a wire type it does not accept as an unknown field" do
    decoded = Mirror3::Scalars.decode("\x0a\x01x\x18\x05".b) # f_double (1) sent length-delimited
    expect(decoded.f_int32).to be(:==, 5)
    expect(decoded.f_double).to be(:==, 0.0)
    expect(decoded.unknown_fields).to be(:==, "\x0a\x01x".b)
    expect(decoded.encode).to be(:==, "\x18\x05\x0a\x01x".b)
  end

  it "bounds nesting depth instead of overflowing the stack" do
    expect(Mirror3::Tree.decode(nested(100)).parent).to be_a(Mirror3::Tree)
    expect { Mirror3::Tree.decode(nested(101)) }.to raise_exception(Fast::Protowire::DecodeError)
    expect { Mirror3::Tree.decode("\x93\x03".b * 5000) }.to raise_exception(Fast::Protowire::DecodeError)
  end

  it "counts messages toward the nesting depth and packed fields not at all" do
    deep = Class.new(Fast::Protowire::Message)
    deep.class_eval do
      field :child, -> { deep }, 1
      repeated :nums, :int32, 2
    end
    leaf = deep.new(nums: [1, 2, 3]).encode
    expect(deep.decode(nested(100, 1, leaf)).child).to be_a(deep)
    expect { deep.decode(nested(101, 1, leaf)) }.to raise_exception(Fast::Protowire::DecodeError)
  end

  it "decodes a map entry whose message value is absent as an empty message" do
    maps = Mirror3::Maps.decode("\x12\x02\x08\x07".b) # an im entry holding its key and nothing else
    expect(maps.im).to be(:==, { 7 => Mirror3::Scalars.new })
    expect(maps.encode).to be(:==, "\x12\x04\x08\x07\x12\x00".b)
  end

  it "keeps a map entry carrying more than a key and a value out of the map, whole" do
    entry = "\x0a\x05\x0a\x01k\x18\x01".b # an ss entry with an undeclared subfield 3
    maps = Mirror3::Maps.decode(entry)
    expect(maps.ss).to be(:==, {})
    expect(maps.unknown_fields).to be(:==, entry)
    expect(maps.encode).to be(:==, entry)
    # Written back as the entry itself would be: its key gone, being at its
    # default, its value and then the bytes it carried besides.
    expect(Mirror3::Maps.decode("\x22\x07\x08\x00\x12\x01v\x18\x01".b).encode).to be(:==, "\x22\x05\x12\x01v\x18\x01".b)
    # A key or value with a wire type the entry does not accept is the same.
    expect(Mirror3::Maps.decode("\x12\x04\x08\x07\x10\x05".b).im).to be(:==, {})
  end

  it "rejects field number 0 and a group closed by another number" do
    expect { Mirror3::Scalars.decode("\x00\x01\x18\x05".b) }.to raise_exception(Fast::Protowire::DecodeError)
    expect { Mirror3::Maps.decode("\x0a\x05\x0a\x01k\x00\x01".b) }.to raise_exception(Fast::Protowire::DecodeError)
    expect { Mirror3::Scalars.decode("\x93\x03\x9c\x03".b) }.to raise_exception(Fast::Protowire::DecodeError)
    group = "\x93\x03\x08\x09\x13\x1d\x01\x02\x03\x04\x14\x94\x03\x18\x07".b # group 50 { 1 = 9, group 2 { 3 } }
    decoded = Mirror3::Scalars.decode(group)
    expect(decoded.f_int32).to be(:==, 7)
    expect(decoded.encode).to be(:==, "\x18\x07#{group[0..-3]}".b) # the group kept whole, after the field
  end

  it "rejects invalid UTF-8 in a proto3 string and keeps it in a proto2 one" do
    expect { Mirror3::Scalars.decode("\x72\x02\xff\xfe".b) }.to raise_exception(Fast::Protowire::DecodeError)
    expect(Mirror3::Scalars.decode("\x72\x02\xc3\xa9".b).f_string).to be(:==, "é")
    expect(Mirror2::Legacy.decode("\x12\x02\xff\xfe".b).o_string.bytes).to be(:==, [0xff, 0xfe])
  end

  it "decodes the same bytes whatever the input String is tagged" do
    bytes = Mirror3::Wide.new(a: 1, b: 2, c: "é").encode
    as_text = Mirror3::Narrow.decode(bytes.dup.force_encoding(Encoding::UTF_8))
    expect(as_text).to be(:==, Mirror3::Narrow.decode(bytes))
    expect(as_text.encode).to be(:==, Mirror3::Narrow.decode(bytes).encode)
    scalars = Mirror3::Scalars.decode(Mirror3::Scalars.new(f_bytes: "\xff".b).encode.force_encoding(Encoding::UTF_8))
    expect(scalars.f_bytes.encoding).to be(:==, Encoding::BINARY)
  end

  it "encodes into an empty buffer of any encoding and refuses a non-binary one holding text" do
    scalars = Mirror3::Scalars.new(f_int32: 200)
    expect(scalars.encode(+"")).to be(:==, scalars.encode)
    expect { scalars.encode(+"prefix") }.to raise_exception(::ArgumentError)
  end

  it "refuses conflicting declarations" do
    expect do
      Class.new(Fast::Protowire::Message) do
        field :a, :int32, 1
        field :b, :int32, 1
      end
    end.to raise_exception(ArgumentError)
    expect { Class.new(Fast::Protowire::Message) { field :a, :nope, 1 } }.to raise_exception(ArgumentError)
    expect { Class.new(Fast::Protowire::Message) { map :a, :double, :string, 1 } }.to raise_exception(ArgumentError)
  end

  it "refuses declarations the wire cannot carry" do
    [0, -1, 1 << 29, 19_000, 19_999].each do |number|
      expect { Class.new(Fast::Protowire::Message) { field :a, :int32, number } }.to raise_exception(ArgumentError)
      expect { Class.new(Fast::Protowire::Message) { map :a, :int32, :int32, number } }
        .to raise_exception(ArgumentError)
    end
    [1, 18_999, 20_000, (1 << 29) - 1].each do |number|
      expect(Class.new(Fast::Protowire::Message) { field :a, :int32, number }.fields_by_number).to be(:key?, number)
    end
    expect { Class.new(Fast::Protowire::Message) { repeated :a, :string, 1, packed: true } }
      .to raise_exception(ArgumentError)
    expect(Class.new(Fast::Protowire::Message) { repeated :a, :int32, 1, packed: true }.fields[:a]).to be(:packed?)
  end
end
