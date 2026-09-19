# frozen_string_literal: true

require "fast/protowire"

describe Fast::Protowire::Wire do
  let(:wire) { Fast::Protowire::Wire }

  it "encodes varints as little-endian base-128" do
    expect(wire.varint(0)).to be(:==, "\x00".b)
    expect(wire.varint(1)).to be(:==, "\x01".b)
    expect(wire.varint(127)).to be(:==, "\x7f".b)
    expect(wire.varint(128)).to be(:==, "\x80\x01".b)
    expect(wire.varint(300)).to be(:==, "\xac\x02".b)
    expect(wire.varint((1 << 64) - 1)).to be(:==, "\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01".b)
  end

  it "sign-extends negative varints to ten bytes" do
    expect(wire.varint(-1)).to be(:==, "\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01".b)
    expect(wire.varint(-2)).to be(:==, "\xfe\xff\xff\xff\xff\xff\xff\xff\xff\x01".b)
  end

  it "zigzags signed integers" do
    expect(wire.zigzag32(0)).to be(:==, 0)
    expect(wire.zigzag32(-1)).to be(:==, 1)
    expect(wire.zigzag32(1)).to be(:==, 2)
    expect(wire.zigzag32(-2)).to be(:==, 3)
    expect(wire.zigzag32(2_147_483_647)).to be(:==, 4_294_967_294)
    expect(wire.zigzag32(-2_147_483_648)).to be(:==, 4_294_967_295)
    expect(wire.zigzag64(-(1 << 63))).to be(:==, (1 << 64) - 1)
    [0, -1, 1, -2, 2_147_483_647, -2_147_483_648, (1 << 62), -(1 << 63)].each do |n|
      expect(wire.unzigzag(wire.zigzag64(n))).to be(:==, n)
    end
  end

  it "builds tags from field number and wire type" do
    expect(wire.tag(1, wire::VARINT)).to be(:==, "\x08".b)
    expect(wire.tag(2, wire::LENGTH_DELIMITED)).to be(:==, "\x12".b)
    expect(wire.tag(16, wire::FIXED64)).to be(:==, "\x81\x01".b)
    expect(wire.tag(536_870_911, wire::FIXED32)).to be(:==, "\xfd\xff\xff\xff\x0f".b)
    expect(wire.tag(1, wire::VARINT)).to be(:frozen?)
  end

  it "appends length-delimited fields" do
    buffer = String.new
    wire.append_length_delimited(buffer, wire.tag(4, wire::LENGTH_DELIMITED), "abc")
    expect(buffer).to be(:==, "\x22\x03abc".b)
  end

  it "sizes varints" do
    sizes = [0, 127, 128, 16_383, 16_384, (1 << 64) - 1, -1].map { |n| wire.varint_size(n) }
    expect(sizes).to be(:==, [1, 1, 2, 2, 3, 10, 10])
  end

  it "appends text of any encoding as bytes and keeps the buffer binary" do
    buffer = String.new
    wire.append_length_delimited(buffer, wire.tag(1, wire::LENGTH_DELIMITED), "héllo")
    wire.append_bytes(buffer, "\xff".b)
    expect(buffer).to be(:==, "\x0a\x06h\xc3\xa9llo\xff".b)
    expect(buffer.encoding).to be(:==, Encoding::BINARY)
  end

  it "retags an empty buffer binary and refuses a non-binary one holding text" do
    expect(wire.binary_buffer(+"").encoding).to be(:==, Encoding::BINARY)
    expect(wire.binary_buffer(String.new).encoding).to be(:==, Encoding::BINARY)
    expect { wire.binary_buffer(+"abc") }.to raise_exception(::ArgumentError)
  end

  it "writes a length prefix behind a payload appended in place, at whatever width the payload turns out to need" do
    tag = wire.tag(2, wire::LENGTH_DELIMITED)
    buffer = String.new
    expected = String.new
    widths = ["abc", "x" * 300, "y", "z" * 20_000].map do |payload|
      wire.append_length_delimited(expected, tag, payload)
      wire.append_length_delimited_from(buffer, tag) { |b| b << payload }
    end
    expect(widths).to be(:==, [1, 2, 1, 3])
    expect(buffer).to be(:==, expected)

    hinted = String.new
    width = wire.append_length_delimited_from(hinted, tag, 2) { |b| b << "abc" }
    expect(width).to be(:==, 1)
    expect(hinted).to be(:==, "\x12\x03abc".b)
  end
end

describe Fast::Protowire::Reader do
  let(:reader_class) { Fast::Protowire::Reader }

  it "reads tags, varints, fixed values and bytes" do
    reader = reader_class.new("\x08\xac\x02\x11\x01\x00\x00\x00\x00\x00\x00\x00\x1d\x02\x00\x00\x00\x22\x02hi".b)
    expect(reader.read_tag).to be(:==, [1, 0])
    expect(reader.read_varint).to be(:==, 300)
    expect(reader.read_tag).to be(:==, [2, 1])
    expect(reader.read_fixed64).to be(:==, 1)
    expect(reader.read_tag).to be(:==, [3, 5])
    expect(reader.read_fixed32).to be(:==, 2)
    expect(reader.read_tag).to be(:==, [4, 2])
    expect(reader.read_length_delimited).to be(:==, "hi")
    expect(reader).to be(:eof?)
  end

  it "skips every wire type and returns the raw bytes, groups included" do
    group = "\x08\x01\x13\x08\x02\x14\x0c".b # field 1 varint, then group 2 { field 1 = 2 } (start 0x13, end 0x14)
    reader = reader_class.new(group)
    reader.read_tag
    expect(reader.skip(0)).to be(:==, "\x01".b)
    expect(reader.read_tag).to be(:==, [2, 3])
    expect(reader.skip(3)).to be(:==, "\x08\x02\x14".b)
    expect(reader.skip(0)).to be(:==, "\x0c".b)
  end

  it "raises DecodeError on truncated input" do
    expect { reader_class.new("\x80".b).read_varint }.to raise_exception(Fast::Protowire::DecodeError)
    expect { reader_class.new("\x22\x05ab".b).tap(&:read_tag).read_length_delimited }
      .to raise_exception(Fast::Protowire::DecodeError)
    expect { reader_class.new("\x01\x00\x00".b).read_fixed32 }.to raise_exception(Fast::Protowire::DecodeError)
    expect { reader_class.new("\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01".b).read_varint }
      .to raise_exception(Fast::Protowire::DecodeError)
  end

  it "truncates a varint carrying bits above 64" do
    expect(reader_class.new("#{"\xff" * 9}\x7f".b).read_varint).to be(:==, (1 << 64) - 1)
    expect(reader_class.new("#{"\x80" * 9}\x02".b).read_varint).to be(:==, 0)
  end

  it "hands out binary slices whatever the input is tagged" do
    reader = reader_class.new("\x02\xc3\xa9\x02\xff\xfe".b.force_encoding(Encoding::UTF_8))
    expect(reader.read_length_delimited).to be(:==, "\xc3\xa9".b)
    expect(reader.skip(2)).to be(:==, "\x02\xff\xfe".b)
  end

  it "bounds itself to a nested value for a block and picks up after it" do
    reader = reader_class.new("\x02\x08\x01\x02\x00\x00\x00".b) # 2 bytes { field 1 = 1 }, then fixed32 2
    inner = reader.read_nested { |nested| [nested.read_tag, nested.read_varint, nested.eof?] }
    expect(inner).to be(:==, [[1, 0], 1, true])
    expect(reader.read_fixed32).to be(:==, 2)
    expect(reader).to be(:eof?)
    expect { reader_class.new("\x01\x08\x01".b).read_nested { |nested| 2.times { nested.read_varint } } }
      .to raise_exception(Fast::Protowire::DecodeError)
    expect { reader_class.new("\x05\x01".b).read_nested { |nested| nested } }
      .to raise_exception(Fast::Protowire::DecodeError)
  end
end
