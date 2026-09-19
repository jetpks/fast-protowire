# frozen_string_literal: true

require_relative "errors"
require_relative "wire"
require_relative "enum"

module Fast
  module Protowire
    # One declared field: its number, type and rule, and how to validate,
    # encode and decode values of it. Built by the Message DSL.
    class Field
      SCALAR_WIRE_TYPES = {
        double: Wire::FIXED64, float: Wire::FIXED32,
        int32: Wire::VARINT, int64: Wire::VARINT, uint32: Wire::VARINT, uint64: Wire::VARINT,
        sint32: Wire::VARINT, sint64: Wire::VARINT, bool: Wire::VARINT, enum: Wire::VARINT,
        fixed32: Wire::FIXED32, sfixed32: Wire::FIXED32, fixed64: Wire::FIXED64, sfixed64: Wire::FIXED64,
        string: Wire::LENGTH_DELIMITED, bytes: Wire::LENGTH_DELIMITED, message: Wire::LENGTH_DELIMITED
      }.freeze

      INTEGER_RANGES = {
        int32: (-(1 << 31))...(1 << 31), sint32: (-(1 << 31))...(1 << 31), sfixed32: (-(1 << 31))...(1 << 31),
        uint32: 0...(1 << 32), fixed32: 0...(1 << 32),
        int64: (-(1 << 63))...(1 << 63), sint64: (-(1 << 63))...(1 << 63), sfixed64: (-(1 << 63))...(1 << 63),
        uint64: 0...(1 << 64), fixed64: 0...(1 << 64)
      }.freeze

      FIXED_FORMATS = { double: "E", float: "e", fixed32: "L<", sfixed32: "l<", fixed64: "Q<", sfixed64: "q<" }.freeze

      PACKABLE = (SCALAR_WIRE_TYPES.keys - %i[string bytes message]).freeze

      MAP_KEY_TYPES = %i[int32 int64 uint32 uint64 sint32 sint64 fixed32 fixed64 sfixed32 sfixed64 bool string].freeze

      private_constant :SCALAR_WIRE_TYPES, :INTEGER_RANGES, :FIXED_FORMATS, :PACKABLE, :MAP_KEY_TYPES

      attr_reader :name, :number, :type, :rule, :oneof, :ivar, :enum

      # +type+ is a scalar Symbol, an Enum module, a Message class, or a
      # String / Proc naming a Message class resolved on first use (for
      # recursive schemas). +rule+ is :implicit, :optional, :required,
      # :repeated or :map.
      def initialize(name, type, number, rule:, owner:, packed: nil, default: nil, oneof: nil, key_type: nil)
        @name = name
        @number = number
        @rule = rule
        @owner = owner
        @oneof = oneof
        @ivar = :"@#{name}"
        resolve_type(type)
        @packed = rule == :repeated && (packed.nil? ? owner.syntax == :proto3 && packable? : packed)
        @default = default
        @tag = Wire.tag(number, packed? ? Wire::LENGTH_DELIMITED : wire_type)
        return unless map?

        raise ArgumentError, "map key type #{key_type.inspect} is not allowed" unless MAP_KEY_TYPES.include?(key_type)

        @key_field = Field.new(:key, key_type, 1, rule: :optional, owner: owner)
        @value_field = Field.new(:value, type, 2, rule: :optional, owner: owner)
      end

      def message_class
        @message_class ||= case @message_ref
                           when Proc then @message_ref.call
                           when String then namespace_of(@owner).const_get(@message_ref)
                           else @message_ref
                           end
      end

      def wire_type
        map? ? Wire::LENGTH_DELIMITED : SCALAR_WIRE_TYPES.fetch(type)
      end

      def repeated?
        rule == :repeated
      end

      def map?
        rule == :map
      end

      def packed?
        @packed
      end

      def packable?
        PACKABLE.include?(type)
      end

      # Whether an unset field is distinguishable from one set to its default.
      def explicit_presence?
        rule != :implicit || !oneof.nil? || type == :message
      end

      def default_value
        case rule
        when :repeated then []
        when :map then {}
        else scalar_default
        end
      end

      # True when a field without presence carries nothing worth emitting.
      # Floats compare bitwise, as the reference encoder does: -0.0 is sent.
      def omit?(value)
        return value.empty? if repeated? || map?

        case type
        when :enum then enum_number(value).zero?
        when :message then false
        when :double, :float then value.zero? && (1.0 / value).positive?
        else value == scalar_default
        end
      end

      # Ruby source that appends this field's value, held in the local +var+,
      # to the local +buffer+ — one straight-line statement per field, which
      # is what the compiled Message#encode is made of.
      def encode_source(var, buffer, enum_ref)
        body = case rule
               when :repeated then if packed?
                                     packed_source(var, buffer,
                                                   enum_ref)
                                   else
                                     unpacked_source(var, buffer, enum_ref)
                                   end
               when :map then map_source(var, buffer, enum_ref)
               else "if #{presence_source(var, enum_ref)}\n  #{one_source(var, buffer, enum_ref)}\nend"
               end
        "#{var} = #{ivar}\n#{body}"
      end

      # Validates and normalizes a value the way an assignment would.
      def coerce(value)
        case rule
        when :repeated
          raise ::TypeError, "#{name} expects an Array" unless value.respond_to?(:to_ary)

          value.to_ary.map { |v| coerce_one(v) }
        when :map
          raise ::TypeError, "#{name} expects a Hash" unless value.respond_to?(:to_hash)

          value.to_hash.to_h { |k, v| [@key_field.coerce_one(k), @value_field.coerce_one(v)] }
        else
          value.nil? ? nil : coerce_one(value)
        end
      end

      def encode(buffer, value)
        case rule
        when :repeated then encode_repeated(buffer, value)
        when :map then encode_map(buffer, value)
        else encode_one(buffer, value)
        end
      end

      # Reads one occurrence of this field into +current+ (the value already
      # held) and returns the value to store.
      def decode(reader, wire_type, current)
        case rule
        when :repeated then decode_repeated(reader, wire_type, current)
        when :map then decode_map_entry(reader, wire_type, current)
        else
          if type == :message && current
            current.merge_from(Reader.new(expect(reader, wire_type).read_length_delimited))
          else
            read_one(reader, wire_type)
          end
        end
      end

      protected

      def one_source(var, buffer, enum_ref)
        case type
        when :message then append_bytes_source(buffer, "#{var}.encode")
        when :string, :bytes then append_bytes_source(buffer, var)
        else "#{buffer} << #{tag_literal}\n#{scalar_source(var, buffer, enum_ref)}"
        end
      end

      def scalar_source(var, buffer, enum_ref)
        wire = "::Fast::Protowire::Wire"
        case type
        when :int32, :int64, :uint32, :uint64 then "#{wire}.append_varint(#{buffer}, #{var})"
        when :sint32 then "#{wire}.append_varint(#{buffer}, #{wire}.zigzag32(#{var}))"
        when :sint64 then "#{wire}.append_varint(#{buffer}, #{wire}.zigzag64(#{var}))"
        when :bool then "#{buffer} << (#{var} ? 1 : 0)"
        when :enum then "#{wire}.append_varint(#{buffer}, #{var}.is_a?(Symbol) ? #{enum_ref}.resolve(#{var}) : #{var})"
        else "[#{var}].pack(#{FIXED_FORMATS.fetch(type).inspect}, buffer: #{buffer})"
        end
      end

      def coerce_one(value)
        case type
        when :string then coerce_string(value)
        when :bytes then coerce_bytes(value)
        when :double, :float then coerce_float(value)
        when :bool then coerce_bool(value)
        when :enum then coerce_enum(value)
        when :message then coerce_message(value)
        else coerce_integer(value)
        end
      end

      def encode_one(buffer, value)
        case type
        when :message then Wire.append_length_delimited(buffer, @tag, value.encode)
        when :string, :bytes then Wire.append_length_delimited(buffer, @tag, value)
        else
          buffer << @tag
          append_scalar(buffer, value)
        end
      end

      def read_one(reader, wire_type)
        expect(reader, wire_type)
        case type
        when :message then message_class.decode(reader.read_length_delimited)
        when :string then reader.read_length_delimited.force_encoding(Encoding::UTF_8)
        when :bytes then reader.read_length_delimited
        else read_scalar(reader)
        end
      end

      private

      def resolve_type(type)
        case type
        when Symbol
          unless SCALAR_WIRE_TYPES.key?(type) && type != :message
            raise ArgumentError,
                  "unknown field type #{type.inspect}"
          end

          @type = type
        when Module
          if type.is_a?(Enum)
            @type = :enum
            @enum = type
          else
            @type = :message
            @message_ref = type
          end
        when String, Proc
          @type = :message
          @message_ref = type
        else
          raise ArgumentError, "unknown field type #{type.inspect}"
        end
      end

      def packed_source(var, buffer, enum_ref)
        "unless #{var}.empty?\n  payload = String.new\n" \
          "  #{var}.each { |e| #{scalar_source('e', 'payload', enum_ref)} }\n" \
          "  #{append_bytes_source(buffer, 'payload')}\nend"
      end

      def unpacked_source(var, buffer, enum_ref)
        "#{var}.each { |e| #{one_source('e', buffer, enum_ref)} }"
      end

      def map_source(var, buffer, enum_ref)
        "#{var}.each do |k, e|\n  entry = String.new\n" \
          "  #{@key_field.one_source('k', 'entry', enum_ref)}\n  #{@value_field.one_source('e', 'entry', enum_ref)}\n" \
          "  #{append_bytes_source(buffer, 'entry')}\nend"
      end

      def append_bytes_source(buffer, bytes)
        "::Fast::Protowire::Wire.append_length_delimited(#{buffer}, #{tag_literal}, #{bytes})"
      end

      def tag_literal
        "\"#{@tag.bytes.map { |b| format('\\x%02x', b) }.join}\""
      end

      # The guard that decides whether a singular field is written at all.
      def presence_source(var, enum_ref)
        return "!#{var}.nil?" if explicit_presence?

        case type
        when :string, :bytes then "#{var} && !#{var}.empty?"
        when :bool then var
        when :enum then "#{var} && (#{var}.is_a?(Symbol) ? #{enum_ref}.resolve(#{var}) : #{var}) != 0"
        when :double, :float then "#{var} && !(#{var}.zero? && (1.0 / #{var}).positive?)"
        else "#{var} && #{var} != #{scalar_default.inspect}"
        end
      end

      # A String type names a class relative to where the owner is declared,
      # so a message can refer to itself or a sibling declared later.
      def namespace_of(owner)
        namespace = owner.name.to_s.rpartition("::").first
        namespace.empty? ? Object : Object.const_get(namespace)
      end

      def scalar_default
        return @default unless @default.nil?

        case type
        when :string then ""
        when :bytes then "".b
        when :double, :float then 0.0
        when :bool then false
        when :enum then @enum.default
        when :message then nil
        else 0
        end
      end

      def enum_number(value)
        value.is_a?(Symbol) ? @enum.resolve(value) : value
      end

      # -- validation --------------------------------------------------------

      def coerce_string(value)
        raise ::TypeError, "#{name} expects a String, got #{value.class}" unless value.is_a?(String)

        string = case value.encoding
                 when Encoding::UTF_8 then value
                 when Encoding::BINARY then value.dup.force_encoding(Encoding::UTF_8)
                 else value.encode(Encoding::UTF_8)
                 end
        raise ::ArgumentError, "#{name}: string is not valid UTF-8" unless string.valid_encoding?

        string
      end

      def coerce_bytes(value)
        raise ::TypeError, "#{name} expects a String, got #{value.class}" unless value.is_a?(String)

        value.encoding == Encoding::BINARY ? value : value.b
      end

      def coerce_float(value)
        raise ::TypeError, "#{name} expects a number, got #{value.class}" unless value.is_a?(Numeric)

        value.to_f
      end

      def coerce_bool(value)
        return value if [true, false].include?(value)

        raise ::TypeError, "#{name} expects true or false, got #{value.class}"
      end

      def coerce_enum(value)
        case value
        when Symbol
          raise ::RangeError, "#{name}: unknown enum value #{value.inspect}" unless @enum.resolve(value)

          value
        when Integer
          raise ::RangeError, "#{name}: #{value} is out of range" unless INTEGER_RANGES[:int32].cover?(value)

          @enum.lookup(value) || value
        else
          raise ::TypeError, "#{name} expects a Symbol or Integer, got #{value.class}"
        end
      end

      def coerce_message(value)
        return message_class.new(value) if value.is_a?(Hash)
        return value if value.is_a?(message_class)

        raise ::TypeError, "#{name} expects a #{message_class}, got #{value.class}"
      end

      def coerce_integer(value)
        raise ::TypeError, "#{name} expects an Integer, got #{value.class}" unless value.is_a?(Numeric)

        integer = value.to_i
        raise ::RangeError, "#{name}: #{value} is not an integer" unless integer == value
        raise ::RangeError, "#{name}: #{value} is out of range" unless INTEGER_RANGES.fetch(type).cover?(integer)

        integer
      end

      # -- encoding ----------------------------------------------------------

      def encode_repeated(buffer, values)
        return if values.empty?

        if packed?
          Wire.append_length_delimited_from(buffer, @tag) { |b| values.each { |v| append_scalar(b, v) } }
        else
          values.each { |v| encode_one(buffer, v) }
        end
      end

      def encode_map(buffer, hash)
        hash.each do |key, value|
          Wire.append_length_delimited_from(buffer, @tag) do |entry|
            @key_field.encode_one(entry, key)
            @value_field.encode_one(entry, value)
          end
        end
      end

      def append_scalar(buffer, value)
        case type
        when :int32, :int64, :uint32, :uint64 then Wire.append_varint(buffer, value)
        when :sint32 then Wire.append_varint(buffer, Wire.zigzag32(value))
        when :sint64 then Wire.append_varint(buffer, Wire.zigzag64(value))
        when :bool then buffer << (value ? 1 : 0)
        when :enum then Wire.append_varint(buffer, enum_number(value))
        else buffer << [value].pack(FIXED_FORMATS.fetch(type))
        end
      end

      # -- decoding ----------------------------------------------------------

      def decode_repeated(reader, wire_type, values)
        if packable? && wire_type == Wire::LENGTH_DELIMITED
          packed = reader.read_packed
          values << read_scalar(packed) until packed.eof?
        else
          values << read_one(reader, wire_type)
        end
        values
      end

      def decode_map_entry(reader, wire_type, hash)
        entry = Reader.new(expect(reader, wire_type).read_length_delimited)
        key = @key_field.default_value
        value = @value_field.default_value
        until entry.eof?
          number, entry_wire_type = entry.read_tag
          case number
          when 1 then key = @key_field.read_one(entry, entry_wire_type)
          when 2 then value = @value_field.decode(entry, entry_wire_type, value)
          else entry.skip(entry_wire_type)
          end
        end
        hash[key] = value
        hash
      end

      def expect(reader, wire_type)
        return reader if wire_type == self.wire_type

        raise DecodeError, "field #{name} (#{number}) has wire type #{wire_type}, expected #{self.wire_type}"
      end

      def read_scalar(reader)
        case type
        when :int32 then signed(reader.read_varint, 32)
        when :enum then coerce_enum(signed(reader.read_varint, 32))
        when :int64 then signed(reader.read_varint, 64)
        when :uint32 then reader.read_varint & 0xFFFF_FFFF
        when :uint64 then reader.read_varint
        when :sint32, :sint64 then Wire.unzigzag(reader.read_varint)
        when :bool then reader.read_varint != 0
        when :double, :fixed64, :sfixed64 then reader.read_bytes(8).unpack1(FIXED_FORMATS.fetch(type))
        else reader.read_bytes(4).unpack1(FIXED_FORMATS.fetch(type))
        end
      end

      def signed(value, bits)
        value &= (1 << bits) - 1
        value >= (1 << (bits - 1)) ? value - (1 << bits) : value
      end
    end
  end
end
