# frozen_string_literal: true

require_relative "lib/vector_mcp/version"

Gem::Specification.new do |spec|
  spec.name = "VectorMCP"
  spec.version = VectorMCP::VERSION
  spec.authors = ["Sergio Bayona"]
  spec.email = ["bayona.sergio@gmail.com"]

  spec.summary = "Ruby implementation of the Model Context Protocol (MCP)"
  spec.description = "Server-side tools for implementing the Model Context Protocol in Ruby applications"
  spec.homepage = "https://github.com/sergiobayona/VectorMCP"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/sergiobayona/VectorMCP"
  spec.metadata["changelog_uri"] = "https://github.com/sergiobayona/VectorMCP/blob/main/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.glob("{lib,exe}/**/*") + %w[LICENSE.txt README.md]
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Runtime dependencies
  spec.add_dependency "async", "~> 2.23.0"
  spec.add_dependency "async-container", "~> 0.16"
  spec.add_dependency "async-http", "~> 0.61"
  spec.add_dependency "async-io", "~> 1.36"
  spec.add_dependency "falcon", "~> 0.42"

  # Development dependencies
  spec.add_development_dependency "bundler", "~> 2.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.12"
  spec.add_development_dependency "rubocop", "~> 1.21"
  spec.add_development_dependency "rubocop-rake", "~> 0.6"
  spec.add_development_dependency "rubocop-rspec", "~> 2.25"
  spec.metadata["rubygems_mfa_required"] = "true"
end
