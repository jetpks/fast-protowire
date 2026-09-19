# frozen_string_literal: true

module Fast
  module Protowire
    # The wire format itself: tags, varints, zigzag, fixed-width values and
    # length prefixes, appended to a binary String buffer, and the size each
    # takes so a length prefix can be written before its payload. Everything
    # above this module is bookkeeping about which field gets which of these.
    module Wire
      VARINT = 0
      FIXED64 = 1
      LENGTH_DELIMITED = 2
      START_GROUP = 3
      END_GROUP = 4
      FIXED32 = 5

      UINT64_MASK = (1 << 64) - 1
      # Zero bytes a length prefix is widened to, by varint width.
      PLACEHOLDERS = Array.new(11) { |width| ("\0" * width).b.freeze }.freeze
      private_constant :UINT64_MASK, :PLACEHOLDERS

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

      # Bytes append_varint writes for +value+.
      def varint_size(value)
        return 10 if value.negative?

        size = 1
        while value > 0x7f
          value >>= 7
          size += 1
        end
        size
      end

      # (* 2 rather than << 1: a left shift of a negative Fixnum allocates.)
      def zigzag32(value)
        (value * 2) ^ (value >> 31)
      end

      def zigzag64(value)
        (value * 2) ^ (value >> 63)
      end

      def unzigzag(value)
        (value >> 1) ^ -(value & 1)
      end

      # A length-delimited field whose payload the block appends to +buffer+
      # itself, behind a length prefix filled in once the payload is there,
      # so a nested message, packed field or map entry costs no buffer of
      # its own. Returns the width of the prefix it wrote: a caller writing
      # many alike values passes it back as +width+ and the prefix is
      # rarely resized.
      def append_length_delimited_from(buffer, tag, width = 1)
        buffer << tag
        start = reserve_length(buffer, width)
        yield buffer
        close_length(buffer, start, width)
      end

      # Appends +width+ placeholder bytes for a length prefix and returns the
      # position after them, for close_length.
      def reserve_length(buffer, width = 1)
        buffer << PLACEHOLDERS[width]
        buffer.bytesize
      end

      # Writes the varint size of everything appended since +start+ into the
      # +width+ placeholder bytes before it, first resizing the placeholder
      # when the size needs a different width, which moves only the payload.
      # Returns the width written. (Growing a String in place reallocates it
      # to exactly the new size, so on a large buffer a resize costs far more
      # than the bytes moved; hence the width hint.)
      def close_length(buffer, start, width = 1)
        length = buffer.bytesize - start
        needed = length < 0x80 ? 1 : varint_size(length)
        buffer.bytesplice(start - width, width, PLACEHOLDERS[needed]) unless needed == width
        position = start - width
        while length > 0x7f
          buffer.setbyte(position, (length & 0x7f) | 0x80)
          position += 1
          length >>= 7
        end
        buffer.setbyte(position, length)
        needed
      end

      # Text of any encoding goes into the binary buffer as bytes. Ruby 3.4's
      # String#append_as_bytes does that with no copy, and takes the tag and
      # a one-byte size in the same call; before it, non-ASCII text is
      # appended as a binary copy so the buffer never trips Ruby's encoding
      # compatibility check.
      if String.method_defined?(:append_as_bytes)
        # A length-delimited field: +tag+, the varint size of +bytes+, +bytes+.
        def append_length_delimited(buffer, tag, bytes)
          size = bytes.bytesize
          return buffer.append_as_bytes(tag, size, bytes) if size < 0x80

          buffer << tag
          append_varint(buffer, size)
          buffer.append_as_bytes(bytes)
        end

        def append_bytes(buffer, bytes)
          buffer.append_as_bytes(bytes)
        end
      else
        def append_length_delimited(buffer, tag, bytes)
          buffer << tag
          append_varint(buffer, bytes.bytesize)
          append_bytes(buffer, bytes)
        end

        def append_bytes(buffer, bytes)
          buffer << (bytes.encoding == Encoding::BINARY || bytes.ascii_only? ? bytes : bytes.b)
        end
      end
    end
  end
end
