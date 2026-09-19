# frozen_string_literal: true

require_relative "errors"
require_relative "wire"
require_relative "reader"
require_relative "field"

module Fast
  module Protowire
    # Base class for declared messages. Subclasses describe their fields with
    # the class-level DSL, mirroring the .proto text:
    #
    #   class LabelPair < Fast::Protowire::Message
    #     syntax :proto2
    #     optional :name, :string, 1
    #     optional :value, :string, 2
    #   end
    #
    #   class Metric < Fast::Protowire::Message
    #     repeated :label, LabelPair, 1
    #     optional :counter, Counter, 3
    #   end
    #
    # +field+ declares proto3 implicit presence (omitted when at the default);
    # +optional+ / +required+ declare explicit presence (has_x? tells set from
    # unset); +repeated+ and +map+ hold Arrays and Hashes; +oneof+ groups
    # fields so setting one clears the others. Fields encode in field-number
    # order, unknown fields survive decode and re-encode, so bytes match what
    # the reference implementation produces for the same values.
    class Message
      class << self
        attr_reader :fields, :fields_by_number, :oneofs

        def inherited(subclass)
          super
          subclass.instance_variable_set(:@fields, {})
          subclass.instance_variable_set(:@fields_by_number, {})
          subclass.instance_variable_set(:@oneofs, {})
          subclass.instance_variable_set(:@syntax, :proto3)
        end

        def syntax(value = nil)
          return @syntax if value.nil?

          raise ArgumentError, "syntax must be :proto2 or :proto3" unless %i[proto2 proto3].include?(value)

          @syntax = value
        end

        # proto3 `type name = N;` — implicit presence. Under proto2 syntax
        # this is the same as +optional+, since proto2 has no implicit fields.
        def field(name, type, number, **options)
          add(name, type, number, rule: @syntax == :proto2 ? :optional : :implicit, **options)
        end

        def optional(name, type, number, **options)
          add(name, type, number, rule: :optional, **options)
        end

        def required(name, type, number, **options)
          add(name, type, number, rule: :required, **options)
        end

        def repeated(name, type, number, packed: nil)
          add(name, type, number, rule: :repeated, packed: packed)
        end

        def map(name, key_type, value_type, number)
          add(name, value_type, number, rule: :map, key_type: key_type)
        end

        # Fields declared inside the block are members of the oneof +name+;
        # the message gains a +name+ reader returning the set member's name.
        def oneof(name, &block)
          raise ArgumentError, "oneof declarations do not nest" if @current_oneof

          @current_oneof = name
          @oneofs[name] = []
          instance_eval(&block)
          members = @oneofs[name]
          define_method(name) { members.find { |member| !instance_variable_get(:"@#{member}").nil? } }
        ensure
          @current_oneof = nil
        end

        def decode(bytes)
          new.merge_from(Reader.new(bytes))
        end

        def encode(message)
          message.encode
        end

        # Enum modules referenced by the compiled encoder, by field index.
        def encoder_enums
          @encoder_enums ||= sorted_fields.map(&:enum)
        end

        # Defines this class's own #encode: one straight-line statement per
        # field in number order, tags as frozen binary literals, no per-field
        # dispatch. Runs once, on the first encode after the last declaration.
        def compile_encoder
          @encoder_enums = nil
          source = +"# encoding: ASCII-8BIT\n# frozen_string_literal: true\ndef encode(buffer = String.new)\n"
          sorted_fields.each_with_index do |field, index|
            source << field.encode_source("v#{index}", "buffer", "self.class.encoder_enums[#{index}]") << "\n"
          end
          source << "buffer << @unknown_fields if @unknown_fields\nbuffer\nend\n"
          class_eval(source, "#{name || 'anonymous'}#encode", 1)
        end

        def sorted_fields
          @sorted_fields ||= @fields.values.sort_by(&:number).freeze
        end

        def container_fields
          @container_fields ||= @fields.values.select { |field| field.repeated? || field.map? }.freeze
        end

        private

        def add(name, type, number, rule:, **options)
          raise ArgumentError, "field #{name} already declared" if @fields.key?(name)
          raise ArgumentError, "field number #{number} already used" if @fields_by_number.key?(number)

          field = Field.new(name, type, number, rule: rule, owner: self, oneof: @current_oneof, **options)
          @fields[name] = field
          @fields_by_number[number] = field
          @oneofs[@current_oneof] << name if @current_oneof
          @sorted_fields = nil
          @container_fields = nil
          remove_method(:encode) if instance_methods(false).include?(:encode)
          define_accessors(field)
        end

        def define_accessors(field)
          ivar = field.ivar
          define_method(field.name) do
            value = instance_variable_get(ivar)
            value.nil? ? field.default_value : value
          end
          define_method(:"#{field.name}=") { |value| write_field(field, field.coerce(value)) }
          return unless field.explicit_presence?

          define_method(:"has_#{field.name}?") { !instance_variable_get(ivar).nil? }
          define_method(:"clear_#{field.name}") { instance_variable_set(ivar, nil) }
        end
      end

      # Scalar and message ivars stay unset until written (an unset ivar reads
      # as nil); repeated and map fields get their container up front so it
      # can be mutated in place.
      def initialize(attributes = nil, **keywords)
        self.class.container_fields.each { |field| instance_variable_set(field.ivar, field.default_value) }
        @unknown_fields = nil
        (attributes || keywords).each do |name, value|
          field = self.class.fields[name.to_sym]
          raise ArgumentError, "unknown field #{name.inspect} for #{self.class}" unless field

          write_field(field, field.coerce(value))
        end
      end

      attr_reader :unknown_fields

      # Appends this message's bytes to +buffer+ and returns it. The first
      # call compiles the class's own encode (see compile_encoder); this
      # generic one is only ever reached before that.
      def encode(buffer = String.new)
        self.class.compile_encoder
        encode(buffer)
      end

      def to_proto(buffer = String.new)
        encode(buffer)
      end

      # Reads fields from +reader+ into this message (protobuf merge
      # semantics: later scalars win, repeated fields append, nested messages
      # merge) and returns self.
      def merge_from(reader)
        until reader.eof?
          number, wire_type = reader.read_tag
          field = self.class.fields_by_number[number]
          if field
            write_field(field, field.decode(reader, wire_type, instance_variable_get(field.ivar)))
          else
            (@unknown_fields ||= String.new) << Wire.varint((number << 3) | wire_type) << reader.skip(wire_type)
          end
        end
        self
      end

      def to_h
        self.class.fields.each_value.with_object({}) do |field, hash|
          value = instance_variable_get(field.ivar)
          next if value.nil? && field.explicit_presence?

          hash[field.name] = hashify(value.nil? ? field.default_value : value)
        end
      end

      # Two messages are equal when every field reads the same; an implicit
      # field set to its default is the same as one never set.
      def ==(other)
        other.class == self.class && comparable_values == other.comparable_values
      end
      alias eql? ==

      def hash
        comparable_values.hash
      end

      def inspect
        set = self.class.fields.each_value.filter_map do |field|
          value = instance_variable_get(field.ivar)
          "#{field.name}: #{value.inspect}" unless value.nil? || field.omit?(value)
        end
        "#<#{self.class.name} #{set.join(', ')}>"
      end

      def initialize_copy(source)
        super
        self.class.fields.each_value do |field|
          value = source.instance_variable_get(field.ivar)
          instance_variable_set(field.ivar, deep_copy(value))
        end
        @unknown_fields = source.unknown_fields&.dup
      end

      protected

      def comparable_values
        values = self.class.fields.each_value.map do |field|
          value = instance_variable_get(field.ivar)
          value.nil? && !field.explicit_presence? ? field.default_value : value
        end
        values << @unknown_fields
      end

      private

      def write_field(field, value)
        if field.oneof && !value.nil?
          self.class.oneofs[field.oneof].each { |member| instance_variable_set(:"@#{member}", nil) }
        end
        instance_variable_set(field.ivar, value)
      end

      def hashify(value)
        case value
        when Message then value.to_h
        when Array then value.map { |v| v.is_a?(Message) ? v.to_h : v }
        when Hash then value.transform_values { |v| v.is_a?(Message) ? v.to_h : v }
        else value
        end
      end

      def deep_copy(value)
        case value
        when Message, String then value.dup
        when Array then value.map { |v| deep_copy(v) }
        when Hash then value.to_h { |k, v| [k, deep_copy(v)] }
        else value
        end
      end
    end
  end
end
