# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name          = "bloop-sdk"
  spec.version       = "0.1.0"
  spec.authors       = ["bloop"]
  spec.summary       = "Ruby SDK for bloop error observability"
  spec.description   = "Capture and send error events to a bloop server. Zero external dependencies."
  spec.homepage      = "https://github.com/your-org/bloop"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.files         = Dir["lib/**/*.rb"]
  spec.require_paths = ["lib"]

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/your-org/bloop/tree/main/sdks/ruby"
end
