# frozen_string_literal: true

# The three "Since 0.1.0" rows of docs/explanation/benchmarks.md, which
# benchmark/messages.rb does not produce: the 36,000-metric family encoded,
# built-from-a-Hash-then-encoded, and decoded, 5 timed calls with GC on and
# objects from one call with GC off, exactly as the page states.
#
#   bundle exec ruby benchmark/since.rb
#   METRICS=5000 RUNS=3 bundle exec ruby benchmark/since.rb

require_relative "../lib/fast/protowire"

$LOAD_PATH.unshift(File.expand_path("../fixtures", __dir__))
require "schema"

LABELS = 12
METRICS = Integer(ENV.fetch("METRICS", 36_000))
RUNS = Integer(ENV.fetch("RUNS", 5))

def family(metrics)
  metric = Array.new(metrics) do |i|
    { label: Array.new(LABELS) { |l| { name: "label_#{l}", value: "label_#{l}-#{i}".ljust(12, "x") } },
      counter: { value: i + 0.5 } }
  end
  { name: "wide_events_total", help: "wide labeled counter", type: :COUNTER, metric: metric }
end

def objects
  GC.start
  GC.disable
  before = GC.stat(:total_allocated_objects)
  yield
  count = GC.stat(:total_allocated_objects) - before
  GC.enable
  GC.start
  count
end

def seconds(&block)
  block.call
  GC.start
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  RUNS.times { block.call }
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / RUNS
end

attributes = family(METRICS)
message = MirrorPrometheus::MetricFamily.new(attributes)
bytes = message.encode

calls = {
  "encode" => -> { message.encode },
  "build from a Hash, encode" => -> { MirrorPrometheus::MetricFamily.new(attributes).encode },
  "decode" => -> { MirrorPrometheus::MetricFamily.decode(bytes) }
}

puts "#{RUBY_DESCRIPTION}; fast-protowire #{Fast::Protowire::VERSION}"
puts "#{METRICS} metrics x #{LABELS} labels, #{bytes.bytesize} bytes, #{RUNS} timed calls"
puts
# Timed first: the warm-up inside +seconds+ pays the first-call costs (the
# compiled encoder, inline caches) so the object count is one settled call.
calls.each do |name, call|
  time = seconds(&call)
  count = objects(&call).to_s.reverse.scan(/\d{1,3}/).join(",").reverse
  puts format("%<name>-26s %<time>.3f s, %<count>s objects", name:, time:, count:)
end
