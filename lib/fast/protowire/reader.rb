# frozen_string_literal: true

require_relative "errors"
require_relative "wire"

module Fast
  module Protowire
    # A cursor over an encoded message. Reads the primitive wire values and
    # skips what it is not asked to interpret.
    class Reader
      # How deep nested messages and groups may go before the input is taken
      # to be hostile rather than deep; the reference's limit.
      MAX_DEPTH = 100

      # Decoding is about bytes, so the input is read as bytes: a String
      # tagged anything else is copied into a binary view once, here, rather
      # than leaking its encoding into every slice handed out below.
      def initialize(buffer, position = 0, limit = buffer.bytesize)
        @buffer = buffer.encoding == Encoding::BINARY ? buffer : buffer.b
        @position = position
        @limit = limit
        @depth = 0
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

      # Most varints (tags, small lengths) are one byte; the loop is only
      # entered past it, and is a bare while because Kernel#loop costs an
      # object per call.
      def read_varint
        byte = read_byte
        return byte if byte < 0x80

        result = byte & 0x7f
        shift = 7
        while byte >= 0x80
          raise DecodeError, "varint too long" if shift > 63

          byte = read_byte
          result |= (byte & 0x7f) << shift
          shift += 7
        end
        # Only a tenth byte can carry bits above 64; every implementation
        # truncates them rather than reading a wider value.
        shift > 63 ? result & Wire::UINT64_MASK : result
      end

      def read_fixed32
        read_fixed("L<", 4)
      end

      def read_fixed64
        read_fixed("Q<", 8)
      end

      # Reads +width+ bytes as one value of the pack +format+, in place.
      def read_fixed(format, width)
        raise DecodeError, "truncated field" if @position + width > @limit

        value = @buffer.unpack1(format, offset: @position)
        @position += width
        value
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

      # Bounds the reader to the next length-delimited value for the block
      # and returns the block's result: nested messages, packed fields and
      # map entries are read in place, with no copy of their bytes. Counts
      # the nesting so deeply nested input raises rather than overflowing the
      # VM stack.
      def read_nested
        length = read_varint
        limit = @limit
        raise DecodeError, "truncated field" if @position + length > limit
        raise DecodeError, "nested deeper than #{MAX_DEPTH}" if @depth >= MAX_DEPTH

        @limit = @position + length
        @depth += 1
        result = yield self
        @depth -= 1
        @position = @limit
        @limit = limit
        result
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

      def read_byte
        raise DecodeError, "truncated varint" if @position >= @limit

        byte = @buffer.getbyte(@position)
        @position += 1
        byte
      end

      def skip_group
        raise DecodeError, "nested deeper than #{MAX_DEPTH}" if @depth >= MAX_DEPTH

        @depth += 1
        loop do
          number, wire_type = read_tag
          break if wire_type == Wire::END_GROUP
          raise DecodeError, "invalid group" if number.zero?

          skip(wire_type)
        end
        @depth -= 1
      end
    end
  end
end
