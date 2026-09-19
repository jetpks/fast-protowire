# frozen_string_literal: true

# The reference implementation's view of the same schemas.
$LOAD_PATH.unshift(File.expand_path("pb", __dir__)) unless $LOAD_PATH.include?(File.expand_path("pb", __dir__))

require "google/protobuf"
require "parity3_pb"
require "parity2_pb"
