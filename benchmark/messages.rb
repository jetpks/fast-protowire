# frozen_string_literal: true

# Message benchmark suite: what declared messages cost against
# google-protobuf, over the Prometheus client model
# (fixtures/proto/metrics.proto) and the parity schemas, in five views.
#
#   1. Encode, by shape: the same attributes built on both sides and encoded
#      to the same bytes: a wide MetricFamily, every scalar type, packed
#      repeated fields, a map, a recursive tree.
#   2. Build, encode, discard: a family constructed from attribute Hashes
#      and encoded once, the way an exposition or a request body is made.
#   3. Decode: the family's bytes back into messages, then read through.
#   4. By size: encode and decode of the family from 1k to 100k metrics.
#   5. Per message: one LabelPair and one Metric, iterations per second.
#
#   bundle exec ruby benchmark/messages.rb            # 36,000 metrics x 12 labels, ~5 minutes
#   BENCH_QUICK=1 bundle exec ruby benchmark/messages.rb
#
# Allocation columns are one call with GC disabled, so they are the call's
# whole footprint: Ruby objects (GC.stat), bytes malloc'd, and for
# google-protobuf the native arenas left alive after it. Timed columns are
# the mean over the timed calls with GC enabled.

require "objspace"
require "benchmark/ips"
require_relative "../lib/fast/protowire"

$LOAD_PATH.unshift(File.expand_path("../fixtures", __dir__))
require "schema"
require "reference"
require "cases"

QUICK = ENV["BENCH_QUICK"]
LABELS = 12
MAIN = Integer(ENV.fetch("METRICS", QUICK ? 5_000 : 36_000))
SIZES = QUICK ? [1_000, MAIN] : [1_000, 10_000, MAIN, 100_000]
RUNS = QUICK ? 3 : 10
PB = Io::Prometheus::Client

# Attribute Hashes that build the same message on both sides.
module Shapes
  def self.metric(index)
    { label: Array.new(LABELS) { |l| { name: "label_#{l}", value: "label_#{l}-#{index}".ljust(12, "x") } },
      counter: { value: index + 0.5 } }
  end

  def self.family(metrics)
    { name: "wide_events_total", help: "wide labeled counter", type: :COUNTER,
      metric: Array.new(metrics) { |i| metric(i) } }
  end

  # name => [declared class, google-protobuf class, attributes]
  def self.all(metrics)
    packed = { r_double: Array.new(10_000) { |i| i * 0.5 }, r_int32: Array.new(10_000) { |i| i } }
    entries = { ss: Array.new(10_000) { |i| ["key-#{i}", "value-#{i}"] }.to_h }
    {
      "MetricFamily, #{Table.commas(metrics)} metrics x #{LABELS} labels" =>
        [MirrorPrometheus::MetricFamily, PB::MetricFamily, family(metrics)],
      "Scalars, every type" => [Mirror3::Scalars, Parity3::Scalars, ParityCases::SCALAR_CASES[1]],
      "Repeated, 10,000 packed doubles + int32s" => [Mirror3::Repeated, Parity3::Repeated, packed],
      "Maps, 10,000 string entries" => [Mirror3::Maps, Parity3::Maps, entries],
      "Tree, depth 3" => [Mirror3::Tree, Parity3::Tree, ParityCases::TREE]
    }
  end
end

module Measure
  # One call with GC off: everything it allocated is still there to count.
  def self.footprint
    GC.start
    GC.disable
    arenas = ObjectSpace.each_object(Google::Protobuf::Internal::Arena).count
    objects = GC.stat(:total_allocated_objects)
    malloc = GC.stat(:malloc_increase_bytes)
    result = yield
    stats = { objects: GC.stat(:total_allocated_objects) - objects,
              malloc_mib: (GC.stat(:malloc_increase_bytes) - malloc) / 1024.0 / 1024,
              arenas: ObjectSpace.each_object(Google::Protobuf::Internal::Arena).count - arenas,
              bytes: result.respond_to?(:bytesize) ? result.bytesize : 0 }
    GC.enable
    GC.start
    stats
  end

  # Timed calls with GC on: what the process pays per call.
  def self.timed(count, &block)
    block.call
    GC.start
    minor = GC.stat(:minor_gc_count)
    major = GC.stat(:major_gc_count)
    gc_ms = GC.stat(:time)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    count.times { block.call }
    seconds = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / count
    { seconds: seconds, minor: GC.stat(:minor_gc_count) - minor, major: GC.stat(:major_gc_count) - major,
      gc_ms: GC.stat(:time) - gc_ms }
  end

  def self.objects_per_call(call, times = 10_000)
    call.call
    GC.start
    before = GC.stat(:total_allocated_objects)
    times.times { call.call }
    (GC.stat(:total_allocated_objects) - before) / times.to_f
  end
end

module Table
  def self.print(title, columns, rows)
    puts "### #{title}"
    puts
    puts "| #{columns.join(' | ')} |"
    puts "|#{'---|' * columns.size}"
    rows.each { |cells| puts "| #{cells.join(' | ')} |" }
    puts
  end

  def self.commas(integer)
    integer.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
  end

  def self.megabytes(bytes)
    "#{(bytes / 1e6).round(2)} MB"
  end

  def self.millis(seconds)
    (seconds * 1000).round(3)
  end

  def self.millions(ips)
    "#{(ips / 1e6).round(2)}M"
  end

  def self.ratio(numerator, denominator)
    "#{(numerator / denominator).round(2)}x"
  end

  # Timed and footprint columns for one call: ms, objects, malloc MiB, arenas, GC.
  def self.cost(call)
    f = Measure.footprint(&call)
    t = Measure.timed(RUNS, &call)
    [millis(t[:seconds]), commas(f[:objects]), f[:malloc_mib].round(1), commas(f[:arenas]),
     "#{t[:minor]} minor + #{t[:major]} major", t[:gc_ms]]
  end
end

COST_COLUMNS = ["ms/call", "objects/call", "malloc MiB/call", "live arenas after", "GC runs (#{RUNS} calls)",
                "GC ms"].freeze

puts "#{RUBY_DESCRIPTION}; google-protobuf #{Gem.loaded_specs['google-protobuf'].version}"
puts "#{Table.commas(MAIN)} metrics x #{LABELS} labels in the family, #{RUNS} timed calls each"
puts

# -- 1. Encode, by shape -------------------------------------------------------

rows = Shapes.all(MAIN).flat_map do |name, (mirror, reference, attributes)|
  ours = mirror.new(attributes)
  theirs = reference.new(attributes)
  # Byte-identical too, but for map entry order, which the parity suite covers.
  equivalent = reference.decode(ours.encode) == theirs && mirror.decode(theirs.to_proto) == ours
  raise "#{name}: not equivalent" unless equivalent

  [["fast-protowire", -> { ours.encode }], ["google-protobuf", -> { theirs.to_proto }]].map do |library, call|
    [name, library, Table.megabytes(ours.encode.bytesize), *Table.cost(call)]
  end
end
Table.print("Encode, by shape (same attributes, same bytes; map entries in each library's order)",
            ["shape", "library", "bytes", *COST_COLUMNS], rows)

# -- 2. Build, encode, discard -------------------------------------------------

attributes = Shapes.family(MAIN)
# Two ways to build the same family: from one nested Hash, which google-protobuf
# converts natively, and a message at a time from live values, the way an
# exposition or a request builder does.
built = lambda do |mod|
  metric = Array.new(MAIN) do |i|
    label = Array.new(LABELS) { |l| mod::LabelPair.new(name: "label_#{l}", value: "label_#{l}-#{i}".ljust(12, "x")) }
    mod::Metric.new(label: label, counter: mod::Counter.new(value: i + 0.5))
  end
  mod::MetricFamily.new(name: "wide_events_total", help: "wide labeled counter", type: :COUNTER, metric: metric)
end
builders = {
  "fast-protowire, from one Hash" => -> { MirrorPrometheus::MetricFamily.new(attributes).encode },
  "google-protobuf, from one Hash" => -> { PB::MetricFamily.new(attributes).to_proto },
  "fast-protowire, a message at a time" => -> { built.call(MirrorPrometheus).encode },
  "google-protobuf, a message at a time" => -> { built.call(PB).to_proto }
}
rows = builders.map { |library, call| [library, *Table.cost(call)] }
Table.print("Build, encode, discard (MetricFamily of #{Table.commas(MAIN)} metrics)", ["library", *COST_COLUMNS], rows)

# -- 3. Decode -----------------------------------------------------------------

bytes = MirrorPrometheus::MetricFamily.new(attributes).encode
read_through = ->(family) { family.metric.each { |metric| metric.label.each(&:value) } }
decoders = {
  "fast-protowire, decode" => -> { MirrorPrometheus::MetricFamily.decode(bytes) },
  "google-protobuf, decode" => -> { PB::MetricFamily.decode(bytes) },
  "fast-protowire, decode and read every label" => lambda {
    read_through.call(MirrorPrometheus::MetricFamily.decode(bytes))
  },
  "google-protobuf, decode and read every label" => -> { read_through.call(PB::MetricFamily.decode(bytes)) }
}
rows = decoders.map { |name, call| [name, *Table.cost(call)] }
Table.print("Decode (#{Table.megabytes(bytes.bytesize)} MetricFamily, #{Table.commas(MAIN)} metrics)",
            ["library", *COST_COLUMNS], rows)

# -- 4. By size ----------------------------------------------------------------

rows = SIZES.map do |size|
  sized = size == MAIN ? attributes : Shapes.family(size)
  ours = MirrorPrometheus::MetricFamily.new(sized)
  theirs = PB::MetricFamily.new(sized)
  sized_bytes = ours.encode
  encode = [-> { ours.encode }, -> { theirs.to_proto }]
  decode = [-> { MirrorPrometheus::MetricFamily.decode(sized_bytes) }, -> { PB::MetricFamily.decode(sized_bytes) }]
  cells = encode.flat_map do |call|
    [Table.millis(Measure.timed(RUNS, &call)[:seconds]), Table.commas(Measure.footprint(&call)[:objects])]
  end
  cells += decode.map { |call| Table.millis(Measure.timed(RUNS, &call)[:seconds]) }
  [Table.commas(size), Table.megabytes(sized_bytes.bytesize), *cells]
end
Table.print("By size (metrics x #{LABELS} labels)",
            ["metrics", "bytes", "fast encode ms", "objects", "google encode ms", "objects", "fast decode ms",
             "google decode ms"], rows)

# -- 5. Per message ------------------------------------------------------------

pair_attributes = { name: "method", value: "GET" }
metric_attributes = Shapes.metric(1)
pair = MirrorPrometheus::LabelPair.new(pair_attributes)
pb_pair = PB::LabelPair.new(pair_attributes)
metric = MirrorPrometheus::Metric.new(metric_attributes)
pb_metric = PB::Metric.new(metric_attributes)
pair_bytes = pair.encode
metric_bytes = metric.encode
operations = {
  "LabelPair encode" => [-> { pair.encode }, -> { pb_pair.to_proto }],
  "Metric encode (#{LABELS} labels)" => [-> { metric.encode }, -> { pb_metric.to_proto }],
  "LabelPair decode" => [-> { MirrorPrometheus::LabelPair.decode(pair_bytes) }, lambda {
    PB::LabelPair.decode(pair_bytes)
  }],
  "Metric decode (#{LABELS} labels)" =>
    [-> { MirrorPrometheus::Metric.decode(metric_bytes) }, -> { PB::Metric.decode(metric_bytes) }],
  "Metric build from Hash + encode" =>
    [-> { MirrorPrometheus::Metric.new(metric_attributes).encode }, -> { PB::Metric.new(metric_attributes).to_proto }]
}
report = Benchmark.ips do |x|
  x.quiet = true
  x.config(time: QUICK ? 0.5 : 2, warmup: QUICK ? 0.2 : 1)
  operations.each do |name, (fast, google)|
    x.report("#{name} fast", &fast)
    x.report("#{name} google", &google)
  end
end
ips = report.entries.to_h { |entry| [entry.label, entry.ips] }
rows = operations.map do |name, (fast, google)|
  fast_ips = ips["#{name} fast"]
  google_ips = ips["#{name} google"]
  [name, Table.millions(fast_ips), Table.millions(google_ips), Table.ratio(fast_ips, google_ips),
   Measure.objects_per_call(fast).round(2), Measure.objects_per_call(google).round(2)]
end
Table.print("Per message",
            ["operation", "fast-protowire i/s", "google-protobuf i/s", "fast / google", "fast-protowire objects/call",
             "google-protobuf objects/call"], rows)
