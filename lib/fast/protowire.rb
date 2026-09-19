# frozen_string_literal: true

require_relative "protowire/version"
require_relative "protowire/errors"
require_relative "protowire/wire"
require_relative "protowire/reader"
require_relative "protowire/enum"
require_relative "protowire/field"
require_relative "protowire/message"

module Fast
  # Protocol Buffers wire format: declare messages, encode and decode bytes.
  # No descriptors, reflection or JSON — the wire layer only.
  module Protowire
  end
end
