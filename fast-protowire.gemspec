# frozen_string_literal: true

require_relative "lib/fast/protowire/version"

Gem::Specification.new do |spec|
  spec.name = "fast-protowire"
  spec.version = Fast::Protowire::VERSION

  spec.summary = "Protocol Buffers wire format for Ruby: declare messages, encode and decode bytes, no runtime."
  spec.authors = ["Eric Jacobs"]
  spec.license = "MIT"

  spec.homepage = "https://github.com/jetpks/fast-protowire"

  spec.required_ruby_version = ">= 3.3"

  spec.files = Dir.glob(["{lib}/**/*", "*.md"], File::FNM_DOTMATCH, base: __dir__)

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/jetpks/fast-protowire"
  spec.metadata["changelog_uri"] = "https://github.com/jetpks/fast-protowire/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"
end
