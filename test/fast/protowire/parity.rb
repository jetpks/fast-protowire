# frozen_string_literal: true

# Byte-for-byte parity with google-protobuf: the same attributes build a
# message on each side; ours must encode to the reference bytes, decode the
# reference bytes to an equal message, and be decodable by the reference.
require "fast/protowire"
require "schema"
require "reference"
require "cases"

describe "parity with google-protobuf" do
  def same_bytes(mirror, reference, attributes)
    ours = mirror.new(attributes)
    theirs = reference.new(attributes)
    bytes = theirs.to_proto
    expect(ours.encode).to be(:==, bytes)
    expect(mirror.decode(bytes).encode).to be(:==, bytes)
    expect(reference.decode(ours.encode)).to be(:==, theirs)
    [ours, theirs]
  end

  def same_message(mirror, reference, attributes)
    ours, theirs = same_bytes(mirror, reference, attributes)
    expect(mirror.decode(theirs.to_proto)).to be(:==, ours)
  end

  it "encodes every scalar type, presence rule and edge value identically" do
    ParityCases::SCALAR_CASES.each { |attributes| same_message(Mirror3::Scalars, Parity3::Scalars, attributes) }
  end

  it "encodes NaN identically" do
    ours, = same_bytes(Mirror3::Scalars, Parity3::Scalars, { f_double: Float::NAN, f_float: Float::NAN })
    expect(Mirror3::Scalars.decode(ours.encode).f_double).to be(:nan?)
  end

  it "encodes packed and unpacked repeated fields identically" do
    ParityCases::REPEATED_CASES.each { |attributes| same_message(Mirror3::Repeated, Parity3::Repeated, attributes) }
  end

  it "encodes oneofs identically, including members set to their default" do
    ParityCases::CHOICE_CASES.each { |attributes| same_message(Mirror3::Choice, Parity3::Choice, attributes) }
  end

  it "encodes single map entries identically and multi-entry maps equivalently" do
    ParityCases::MAP_CASES.each { |attributes| same_message(Mirror3::Maps, Parity3::Maps, attributes) }

    ParityCases::MULTI_MAP_CASES.each do |attributes|
      ours = Mirror3::Maps.new(attributes)
      theirs = Parity3::Maps.new(attributes)
      expect(Mirror3::Maps.decode(theirs.to_proto)).to be(:==, ours)
      expect(Parity3::Maps.decode(ours.encode)).to be(:==, theirs)
      expect(Mirror3::Maps.decode(ours.encode)).to be(:==, ours)
    end
  end

  it "encodes recursive messages identically" do
    same_message(Mirror3::Tree, Parity3::Tree, ParityCases::TREE)
  end

  it "encodes proto2 presence, defaults and unpacked repeated fields identically" do
    ParityCases::LEGACY_CASES.each { |attributes| same_message(Mirror2::Legacy, Parity2::Legacy, attributes) }
  end

  it "encodes the Prometheus client model identically" do
    ParityCases::PROMETHEUS_CASES.each do |attributes|
      same_message(MirrorPrometheus::MetricFamily, Io::Prometheus::Client::MetricFamily, attributes)
    end
  end

  it "preserves unknown fields through decode and encode, in the reference's order" do
    bytes = Parity3::Wide.new(a: 1, b: 2, c: "x").to_proto
    ours = Mirror3::Narrow.decode(bytes)
    expect(ours.b).to be(:==, 2)
    expect(ours.encode).to be(:==, Parity3::Narrow.decode(bytes).to_proto)
    expect(Parity3::Wide.decode(ours.encode)).to be(:==, Parity3::Wide.new(a: 1, b: 2, c: "x"))
  end

  it "decodes bytes the DSL cannot express to the same values and bytes the reference does" do
    ParityCases::SCALARS_DECODE_CASES.each_value do |bytes|
      ours = Mirror3::Scalars.decode(bytes)
      theirs = Parity3::Scalars.decode(bytes)
      %i[f_int32 f_uint64 f_sint32 f_sint64].each { |f| expect(ours.public_send(f)).to be(:==, theirs.public_send(f)) }
      expect(ours.encode).to be(:==, theirs.to_proto)
    end

    ParityCases::MAPS_DECODE_CASES.each_value do |bytes|
      ours = Mirror3::Maps.decode(bytes)
      theirs = Parity3::Maps.decode(bytes)
      %i[ss si bs].each { |f| expect(ours.public_send(f)).to be(:==, theirs.public_send(f).to_h) }
      expect(ours.im.keys).to be(:==, theirs.im.keys.to_a)
      expect(ours.encode).to be(:==, theirs.to_proto)
    end
  end

  it "decodes a UTF-8-tagged input to the bytes the reference decodes it to" do
    ParityCases::SCALARS_DECODE_CASES.each_value do |bytes|
      as_text = bytes.dup.force_encoding(Encoding::UTF_8)
      expect(Mirror3::Scalars.decode(as_text).encode).to be(:==, Parity3::Scalars.decode(bytes).to_proto)
    end
  end

  it "encodes into an empty buffer of any encoding as it does into a binary one" do
    ParityCases::SCALAR_CASES.each do |attributes|
      expect(Mirror3::Scalars.new(attributes).encode(+"")).to be(:==, Parity3::Scalars.new(attributes).to_proto)
    end
  end

  it "merges concatenated encodings the way the reference does" do
    bytes = Parity3::Scalars.new(f_int32: 1, f_string: "old", child: { f_int32: 1 }).to_proto +
            Parity3::Scalars.new(f_string: "new", child: { f_string: "c" }).to_proto
    ours = Mirror3::Scalars.decode(bytes)
    theirs = Parity3::Scalars.decode(bytes)
    %i[f_int32 f_string].each { |f| expect(ours.public_send(f)).to be(:==, theirs.public_send(f)) }
    expect(ours.child.f_int32).to be(:==, theirs.child.f_int32)
    expect(ours.child.f_string).to be(:==, theirs.child.f_string)
    expect(ours.encode).to be(:==, theirs.to_proto)
  end
end
