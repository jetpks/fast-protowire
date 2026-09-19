# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :test do
  gem "sus"
  gem "covered"
  gem "rubocop"
  # The reference encoder the parity suite compares bytes against. Never a
  # runtime dependency.
  gem "google-protobuf", "~> 4.36"
end
