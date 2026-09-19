# frozen_string_literal: true

module Fast
  module Protowire
    # The wire format itself: tags, varints, zigzag, fixed-width values and
    # length prefixes, appended to a binary String buffer. Everything above
    # this module is bookkeeping about which field gets which of these.
    module Wire
      VARINT = 0
      FIXED64 = 1
      LENGTH_DELIMITED = 2
      START_GROUP = 3
      END_GROUP = 4
      FIXED32 = 5

      UINT64_MASK = (1 << 64) - 1
      private_constant :UINT64_MASK

      module_function

      # The key for +number+ / +wire_type+ as frozen bytes.
      def tag(number, wire_type)
        varint((number << 3) | wire_type).freeze
      end

      def varint(value)
        append_varint(String.new(capacity: 10), value)
      end

      # Base-128 little-endian; negative values are sign-extended to 64 bits
      # exactly as int32/int64 fields require (ten bytes).
      def append_varint(buffer, value)
        value &= UINT64_MASK if value.negative?
        while value > 0x7f
          buffer << ((value & 0x7f) | 0x80)
          value >>= 7
        end
        buffer << value
      end

      def zigzag32(value)
        (value << 1) ^ (value >> 31)
      end

      def zigzag64(value)
        (value << 1) ^ (value >> 63)
      end

      def unzigzag(value)
        (value >> 1) ^ -(value & 1)
      end

      # A length-delimited field: +tag+ then the varint size of +bytes+ then
      # +bytes+. Non-ASCII text is appended as its bytes so the binary buffer
      # never trips Ruby's encoding compatibility check.
      def append_length_delimited(buffer, tag, bytes)
        buffer << tag
        append_varint(buffer, bytes.bytesize)
        buffer << (bytes.ascii_only? ? bytes : bytes.b)
      end
    end
  end
end
