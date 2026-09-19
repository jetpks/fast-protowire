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

      # The field numbers a tag can carry, less the range the specification
      # reserves for the implementation.
      NUMBERS = (1..(1 << 29) - 1)
      RESERVED_NUMBERS = (19_000..19_999)

      private_constant :SCALAR_WIRE_TYPES, :INTEGER_RANGES, :FIXED_FORMATS, :PACKABLE, :MAP_KEY_TYPES,
                       :NUMBERS, :RESERVED_NUMBERS

      attr_reader :name, :number, :type, :rule, :oneof, :ivar, :enum

      # +type+ is a scalar Symbol, an Enum module, a Message class, or a
      # String / Proc naming a Message class resolved on first use (for
      # recursive schemas). +rule+ is :implicit, :optional, :required,
      # :repeated or :map.
      def initialize(name, type, number, rule:, owner:, packed: nil, default: nil, oneof: nil, key_type: nil)
        @name = name
        @number = validate_number(number)
        @rule = rule
        @owner = owner
        @oneof = oneof
        @ivar = :"@#{name}"
        resolve_type(type)
        raise ArgumentError, "#{name}: a #{@type} field cannot be packed" if packed && !packable?

        @packed = rule == :repeated && (packed.nil? ? owner.syntax == :proto3 && packable? : packed)
        @strict_utf8 = @type == :string && owner.syntax == :proto3
        @default = default
        @tag = Wire.tag(number, packed? ? Wire::LENGTH_DELIMITED : wire_type)
        return unless map?

        raise ArgumentError, "map key type #{key_type.inspect} is not allowed" unless MAP_KEY_TYPES.include?(key_type)

        @key_field = Field.new(:key, key_type, 1, rule: :optional, owner: owner)
        @value_field = Field.new(:value, type, 2, rule: :optional, owner: owner)
        # The only two tags an entry accepts: number and wire type together.
        @key_tag = (1 << 3) | @key_field.wire_type
        @value_tag = (2 << 3) | @value_field.wire_type
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

      # Whether a value of +wire_type+ can be read into this field: its own,
      # plus the packed form of a packable repeated field however it was
      # declared. Anything else is schema drift, kept as an unknown field.
      def accepts?(wire_type)
        wire_type == self.wire_type || (repeated? && packable? && wire_type == Wire::LENGTH_DELIMITED)
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

      # A step of the compiled Message#encode: a lambda taking the message
      # and the buffer that appends this field, or nothing when the field is
      # unset or at a default it need not send. Everything the step needs
      # (ivar name, tag bytes, enum, nested writers) is captured when it is
      # built, so encoding does no per-field dispatch.
      def encoder_step
        ivar = @ivar
        case rule
        when :repeated then repeated_step(ivar)
        when :map then map_step(ivar)
        else singular_step(ivar)
        end
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

      # Reads one occurrence of this field into +current+ (the value already
      # held) and returns the value to store. +message+ is the message being
      # read into, for a map entry it cannot accept: that belongs among the
      # message's unknown fields rather than in the map.
      def decode(reader, wire_type, current, message)
        case rule
        when :repeated then decode_repeated(reader, wire_type, current)
        when :map then decode_map_entry(reader, wire_type, current, message)
        else decode_singular(reader, wire_type, current)
        end
      end

      protected

      # A second occurrence of a message field merges into the first; of
      # anything else, replaces it. (A map's value field is read this way by
      # the map field, which is why this is protected rather than private.)
      def decode_singular(reader, wire_type, current)
        return read_one(reader, wire_type) unless type == :message && current

        expect(reader, wire_type).read_nested { |nested| current.merge_from(nested) }
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

      def read_one(reader, wire_type)
        expect(reader, wire_type)
        case type
        when :message then reader.read_nested { |nested| message_class.new.merge_from(nested) }
        when :string then read_string(reader)
        when :bytes then reader.read_length_delimited
        else read_scalar(reader)
        end
      end

      # What a map entry holds for this field when the entry omits it: the
      # type's default, except that a message value is an empty instance, as
      # the reference materialises one (and nil would not encode).
      def entry_default
        type == :message ? message_class.new : default_value
      end

      # Appends the tag and one value. A nested message is encoded straight
      # into the buffer behind a length prefix filled in after it, with no
      # buffer of its own; +width+ carries the prefix width from one value
      # to the next, a hint shared by every encode of the field. (A map's
      # key and value fields build the entry writer together, which is why
      # this is protected rather than private.)
      def writer
        tag = @tag
        case type
        when :message
          width = 1
          ->(buffer, value) { width = Wire.append_length_delimited_from(buffer, tag, width) { |b| value.encode(b) } }
        when :string, :bytes then ->(buffer, value) { Wire.append_length_delimited(buffer, tag, value) }
        else
          scalar = scalar_writer
          lambda do |buffer, value|
            buffer << tag
            scalar.call(buffer, value)
          end
        end
      end

      private

      def validate_number(number)
        raise ArgumentError, "field number #{number} is reserved" if RESERVED_NUMBERS.cover?(number)
        raise ArgumentError, "field number #{number} is outside #{NUMBERS}" unless NUMBERS.cover?(number)

        number
      end

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

      # -- compiled encoder steps --------------------------------------------

      def singular_step(ivar)
        write = writer
        if explicit_presence?
          ->(message, buffer) { (value = message.instance_variable_get(ivar)).nil? || write.call(buffer, value) }
        else
          omit = omitter
          lambda do |message, buffer|
            value = message.instance_variable_get(ivar)
            write.call(buffer, value) unless value.nil? || omit.call(value)
          end
        end
      end

      # Packed: every value bare, behind one tag and length.
      def repeated_step(ivar)
        if packed?
          tag = @tag
          scalar = scalar_writer
          width = 1
          lambda do |message, buffer|
            values = message.instance_variable_get(ivar)
            next if values.empty?

            width = Wire.append_length_delimited_from(buffer, tag, width) do |b|
              values.each { |value| scalar.call(b, value) }
            end
          end
        else
          write = writer
          ->(message, buffer) { message.instance_variable_get(ivar).each { |value| write.call(buffer, value) } }
        end
      end

      # Each entry is a message { key = 1; value = 2 }.
      def map_step(ivar)
        tag = @tag
        key, value = entry_writers
        width = 1
        lambda do |message, buffer|
          message.instance_variable_get(ivar).each do |k, v|
            width = Wire.append_length_delimited_from(buffer, tag, width) do |b|
              key.call(b, k)
              value.call(b, v)
            end
          end
        end
      end

      # -- writers -----------------------------------------------------------

      # Appends one scalar value without its tag, as packed fields need.
      # Fixed-width types get a lambda each so the pack format is a literal:
      # Ruby elides the Array in [value].pack(literal, buffer:), and only then.
      def scalar_writer
        case type
        when :int32, :int64, :uint32, :uint64 then ->(buffer, value) { Wire.append_varint(buffer, value) }
        when :sint32 then ->(buffer, value) { Wire.append_varint(buffer, Wire.zigzag32(value)) }
        when :sint64 then ->(buffer, value) { Wire.append_varint(buffer, Wire.zigzag64(value)) }
        when :bool then ->(buffer, value) { buffer << (value ? 1 : 0) }
        when :enum
          enum = @enum
          ->(buffer, value) { Wire.append_varint(buffer, value.is_a?(Symbol) ? enum.resolve(value) : value) }
        when :double then ->(buffer, value) { [value].pack("E", buffer: buffer) }
        when :float then ->(buffer, value) { [value].pack("e", buffer: buffer) }
        when :fixed32 then ->(buffer, value) { [value].pack("L<", buffer: buffer) }
        when :sfixed32 then ->(buffer, value) { [value].pack("l<", buffer: buffer) }
        when :fixed64 then ->(buffer, value) { [value].pack("Q<", buffer: buffer) }
        when :sfixed64 then ->(buffer, value) { [value].pack("q<", buffer: buffer) }
        end
      end

      # Decides whether a field without presence is at a value it need not
      # send. Floats compare bitwise, as the reference encoder does.
      def omitter
        case type
        when :string, :bytes then ->(value) { value.empty? } # rubocop:disable Style/SymbolProc
        when :bool then ->(value) { !value } # rubocop:disable Style/SymbolProc
        when :double, :float then ->(value) { value.zero? && (1.0 / value).positive? }
        when :enum
          enum = @enum
          ->(value) { (value.is_a?(Symbol) ? enum.resolve(value) : value).zero? }
        else
          default = scalar_default
          ->(value) { value == default }
        end
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

      # A +float+ holds what the wire holds: the value narrowed to single
      # precision on assignment, as the reference narrows it, so what is
      # read back is what a decode of the encoding reads.
      def coerce_float(value)
        raise ::TypeError, "#{name} expects a number, got #{value.class}" unless value.is_a?(Numeric)

        type == :float ? [value.to_f].pack("e").unpack1("e") : value.to_f
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

      # -- decoding ----------------------------------------------------------

      def decode_repeated(reader, wire_type, values)
        if packable? && wire_type == Wire::LENGTH_DELIMITED
          reader.read_packed { |packed| values << read_scalar(packed) until packed.eof? }
        else
          values << read_one(reader, wire_type)
        end
        values
      end

      # An entry the map accepts holds its key, its value, or both; one that
      # carries anything else — an undeclared subfield, or the key or value
      # with a wire type the entry does not accept — is not a map entry at
      # all. The reference keeps such an entry among the parent message's
      # unknown fields and leaves the map alone, so this does too.
      def decode_map_entry(reader, wire_type, hash, message)
        expect(reader, wire_type).read_nested do |entry|
          key = nil
          value = nil
          unknown = nil
          until entry.eof?
            tag = entry.read_key
            case tag
            when @key_tag then key = @key_field.read_one(entry, tag & 0x7)
            when @value_tag then value = @value_field.decode_singular(entry, tag & 0x7, value)
            else
              Wire.append_varint(unknown ||= String.new, tag)
              unknown << entry.skip(tag & 0x7, tag >> 3)
            end
          end
          if unknown
            keep_entry(message, key, value, unknown)
          else
            # An absent key or value reads as its type's default, an empty
            # message for a message-typed value, as the reference
            # materialises one. (Only nil is absent: false is a bool key.)
            hash[key.nil? ? @key_field.default_value : key] = value.nil? ? @value_field.entry_default : value
          end
        end
        hash
      end

      # A rejected entry, into the message's unknown fields (its own buffer,
      # made here when the message has none yet) and written the way the
      # reference writes one: the subfields it did carry, in number order and
      # omitted when they are at their default — a message value is written
      # whenever it was there — then the bytes it carried besides.
      def keep_entry(message, key, value, unknown)
        buffer = message.unknown_fields || message.instance_variable_set(:@unknown_fields, String.new)
        write_key, write_value = entry_writers
        Wire.append_length_delimited_from(buffer, @tag) do |b|
          write_key.call(b, key) unless key.nil? || @key_field.omit?(key)
          write_value.call(b, value) unless value.nil? || @value_field.omit?(value)
          b << unknown
        end
      end

      def entry_writers
        @entry_writers ||= [@key_field.writer, @value_field.writer]
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
        when :sint32 then Wire.unzigzag(reader.read_varint & 0xFFFF_FFFF)
        when :sint64 then Wire.unzigzag(reader.read_varint)
        when :bool then reader.read_varint != 0
        when :double, :fixed64, :sfixed64 then reader.read_fixed(FIXED_FORMATS.fetch(type), 8)
        else reader.read_fixed(FIXED_FORMATS.fetch(type), 4)
        end
      end

      # proto3 requires a parser to reject a string field that is not valid
      # UTF-8; proto2 does not, and the reference keeps it.
      def read_string(reader)
        string = reader.read_length_delimited.force_encoding(Encoding::UTF_8)
        raise DecodeError, "#{name}: string is not valid UTF-8" if @strict_utf8 && !string.valid_encoding?

        string
      end

      def signed(value, bits)
        value &= (1 << bits) - 1
        value >= (1 << (bits - 1)) ? value - (1 << bits) : value
      end
    end
  end
end
