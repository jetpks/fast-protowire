# frozen_string_literal: true

require "fast/protowire"
require "schema"

describe Fast::Protowire::Message do
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

  it "rejects a known field arriving with the wrong wire type" do
    expect { Mirror3::Scalars.decode("\x0a\x01x".b) }.to raise_exception(Fast::Protowire::DecodeError)
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
end
