# frozen_string_literal: true

module Fast
  module Protowire
    class Error < StandardError; end

    # Bytes that do not parse as a message of the declared shape.
    class DecodeError < Error; end
  end
end
