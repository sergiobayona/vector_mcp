# frozen_string_literal: true

require_relative "lib/vector_mcp/version"

Gem::Specification.new do |spec|
  spec.name = "vector_mcp"
  spec.version = VectorMCP::VERSION
  spec.authors = ["Sergio Bayona"]
  spec.email = ["bayona.sergio@gmail.com"]

  spec.summary = "Ruby implementation of the Model Context Protocol (MCP)"
  spec.description = "Server-side tools for implementing the Model Context Protocol in Ruby applications"
  spec.homepage = "https://github.com/sergiobayona/vector_mcp"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/sergiobayona/vector_mcp"
  spec.metadata["changelog_uri"] = "https://github.com/sergiobayona/vector_mcp/blob/main/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.glob("{lib,bin}/**/*") + %w[LICENSE.txt README.md]
  spec.bindir = "bin"
  spec.executables = spec.files.grep(%r{\Abin/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Runtime dependencies
  spec.add_dependency "async", "~> 2.23.0"
  spec.add_dependency "async-container", "~> 0.16"
  spec.add_dependency "async-http", "~> 0.61"
  spec.add_dependency "async-io", "~> 1.36"
  spec.add_dependency "base64", "~> 0.2"
  spec.add_dependency "falcon", "~> 0.42"

  spec.metadata["rubygems_mfa_required"] = "true"
end
