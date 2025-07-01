# frozen_string_literal: true

require_relative "lib/vector_mcp/version"

Gem::Specification.new do |spec|
  spec.name = "vector_mcp"
  spec.version = VectorMCP::VERSION
  spec.authors = ["Sergio Bayona"]
  spec.email = ["bayona.sergio@gmail.com"]

  spec.summary = "Ruby implementation of the Model Context Protocol (MCP)"
  spec.description = "A Ruby gem implementing the Model Context Protocol (MCP) server-side specification. " \
                     "Provides a framework for creating MCP servers that expose tools, resources, prompts, and roots to LLM clients " \
                     "with comprehensive security features, structured logging, and production-ready capabilities."
  spec.homepage = "https://github.com/sergiobayona/vector_mcp"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.6"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/sergiobayona/vector_mcp"
  spec.metadata["changelog_uri"] = "https://github.com/sergiobayona/vector_mcp/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  spec.files = Dir.glob("{lib,bin}/**/*") + %w[LICENSE.txt README.md CHANGELOG.md]
  spec.bindir = "bin"
  spec.executables = spec.files.grep(%r{\Abin/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Dependencies
  spec.add_dependency "base64", "~> 0.2"
  spec.add_dependency "bigdecimal", "~> 3.1"
  spec.add_dependency "concurrent-ruby", "~> 1.2"
  spec.add_dependency "json-schema", "~> 3.0"
  spec.add_dependency "jwt", "~> 2.7"
  spec.add_dependency "puma", "~> 6.4"
  spec.add_dependency "rack", "~> 3.0"
end
