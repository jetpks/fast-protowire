# frozen_string_literal: true

require "fast/protowire"
require "schema"
require "cases"

# Allocation budgets for encode, decode and construction: what a message
# costs in Ruby objects beyond its own output. Counts are GC.stat, exact and
# the same on every platform, but for one Ruby-version difference: Array#pack
# for a fixed-width value costs an Array before Ruby 3.4 and nothing from it,
# so that cost is measured here rather than assumed. Everything a measured
# block touches is a local: a `let` costs an object per read.
describe "allocations" do
  # Objects allocated per run of the block, averaged over +times+ runs so a
  # one-off allocation outside the block (GC.stat's own, under coverage)
  # does not count.
  def allocations(times = 100, &block)
    before = GC.stat(:total_allocated_objects)
    times.times(&block)
    (GC.stat(:total_allocated_objects) - before) / times.to_f
  end

  # What one fixed-width write costs on this Ruby, from a lambda as the
  # compiled writers are.
  def pack_cost
    pack = ->(buffer) { [1.5].pack("E", buffer: buffer) }
    buffer = String.new
    pack.call(buffer)
    allocations { pack.call(buffer.clear) }
  end

  def family(metrics, labels)
    MirrorPrometheus::MetricFamily.new(
      name: "wide", type: :COUNTER,
      metric: Array.new(metrics) do |i|
        { label: Array.new(labels) { |l| { name: "label_#{l}", value: "value_#{l}_#{i}" } },
          counter: { value: i + 0.5 } }
      end
    )
  end

  it "encodes a family of nested messages in one object, the output" do
    wide = family(100, 4)
    wide.encode
    expect(allocations(10) { wide.encode }).to be(:<, 2 + (100 * pack_cost))
  end

  it "encodes into a caller's buffer without allocating" do
    buffer = String.new
    tree = Mirror3::Tree.new(ParityCases::TREE)
    tree.encode(buffer)
    expect(allocations { tree.encode(buffer.clear) }).to be(:<, 1)
  end

  it "encodes packed fields and maps without a buffer per entry" do
    buffer = String.new
    repeated = Mirror3::Repeated.new(r_int32: Array.new(100) { |i| i }, r_sint64: Array.new(100) { |i| 50 - i })
    maps = Mirror3::Maps.new(ss: Array.new(100) { |i| ["k#{i}", "v#{i}"] }.to_h,
                             si: Array.new(100) { |i| ["k#{i}", i] }.to_h)
    repeated.encode(buffer)
    maps.encode(buffer)
    expect(allocations { repeated.encode(buffer.clear) }).to be(:<, 1)
    expect(allocations { maps.encode(buffer.clear) }).to be(:<, 1)
  end

  it "decodes in one object per message, per container and per string" do
    bytes = family(100, 4).encode
    MirrorPrometheus::MetricFamily.decode(bytes)
    per_metric = 3 + (4 * 3) # the Metric, its label Array and its Counter; a LabelPair and two Strings per label
    expect(allocations(10) { MirrorPrometheus::MetricFamily.decode(bytes) }).to be(:<, (100 * per_metric) + 10)
  end

  it "decodes a text-tagged input for one object more, the binary view of it" do
    bytes = family(10, 4).encode
    text = bytes.dup.force_encoding(Encoding::UTF_8)
    MirrorPrometheus::MetricFamily.decode(text)
    binary = allocations(10) { MirrorPrometheus::MetricFamily.decode(bytes) }
    expect(allocations(10) { MirrorPrometheus::MetricFamily.decode(text) }).to be(:<, binary + 2)
  end

  it "builds a message from a Hash in one object per message plus its containers" do
    attributes = { name: "method", value: "GET" }
    MirrorPrometheus::LabelPair.new(attributes)
    expect(allocations { MirrorPrometheus::LabelPair.new(attributes) }).to be(:<, 2)
    metric = family(1, 4).metric.first.to_h
    MirrorPrometheus::Metric.new(metric)
    # The Metric, its Counter, a LabelPair per label, the label Array and its coerced copy.
    expect(allocations { MirrorPrometheus::Metric.new(metric) }).to be(:<, 5 + 4)
  end
end
