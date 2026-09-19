# frozen_string_literal: true

module Fast
  module Protowire
    # Builds an enum module: one constant per value, plus lookup in both
    # directions. Fields declared with the module store Symbols for known
    # values and Integers for values the module does not name.
    #
    #   MetricType = Fast::Protowire::Enum.define(COUNTER: 0, GAUGE: 1)
    #   MetricType::GAUGE           # => 1
    #   MetricType.lookup(1)        # => :GAUGE
    #   MetricType.resolve(:GAUGE)  # => 1
    module Enum
      def self.define(**values)
        Module.new do
          extend Enum
          values.each { |name, number| const_set(name, number) }
          @by_name = values.freeze
          @by_number = values.invert.freeze
        end
      end

      def lookup(number)
        @by_number[number]
      end

      def resolve(name)
        @by_name[name]
      end

      def values
        @by_name
      end

      # The value an unset field reads as: proto3 requires a zero value,
      # proto2 falls back to the first declared one.
      def default
        @by_number[0] || @by_name.each_key.first
      end
    end
  end
end
