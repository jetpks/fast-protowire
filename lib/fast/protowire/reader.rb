# frozen_string_literal: true

require_relative "errors"
require_relative "wire"

module Fast
  module Protowire
    # A cursor over an encoded message. Reads the primitive wire values and
    # skips what it is not asked to interpret.
    class Reader
      def initialize(buffer, position = 0, limit = buffer.bytesize)
        @buffer = buffer
        @position = position
        @limit = limit
      end

      attr_reader :position

      def eof?
        @position >= @limit
      end

      # Returns [field number, wire type].
      def read_tag
        key = read_varint
        [key >> 3, key & 0x7]
      end

      def read_varint
        result = 0
        shift = 0
        loop do
          raise DecodeError, "truncated varint" if @position >= @limit

          byte = @buffer.getbyte(@position)
          @position += 1
          result |= (byte & 0x7f) << shift
          return result if byte < 0x80

          shift += 7
          raise DecodeError, "varint too long" if shift > 63
        end
      end

      def read_fixed32
        read_bytes(4).unpack1("L<")
      end

      def read_fixed64
        read_bytes(8).unpack1("Q<")
      end

      def read_bytes(length)
        raise DecodeError, "truncated field" if @position + length > @limit

        bytes = @buffer.byteslice(@position, length)
        @position += length
        bytes
      end

      def read_length_delimited
        read_bytes(read_varint)
      end

      # A reader bounded to the next length-delimited value, for packed fields.
      def read_packed
        length = read_varint
        raise DecodeError, "truncated packed field" if @position + length > @limit

        reader = Reader.new(@buffer, @position, @position + length)
        @position += length
        reader
      end

      # Skips one value of +wire_type+ and returns its raw bytes, so unknown
      # fields survive a decode/encode round trip.
      def skip(wire_type)
        start = @position
        case wire_type
        when Wire::VARINT then read_varint
        when Wire::FIXED64 then read_bytes(8)
        when Wire::LENGTH_DELIMITED then read_length_delimited
        when Wire::START_GROUP then skip_group
        when Wire::FIXED32 then read_bytes(4)
        else raise DecodeError, "unknown wire type #{wire_type}"
        end
        @buffer.byteslice(start, @position - start)
      end

      private

      def skip_group
        loop do
          number, wire_type = read_tag
          return if wire_type == Wire::END_GROUP
          raise DecodeError, "invalid group" if number.zero?

          skip(wire_type)
        end
      end
    end
  end
end
