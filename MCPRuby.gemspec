# frozen_string_literal: true

require_relative "lib/mcp_ruby/version"

Gem::Specification.new do |spec|
  spec.name = "MCPRuby"
  spec.version = MCPRuby::VERSION
  spec.authors = ["Sergio Bayona"]
  spec.email = ["bayona.sergio@gmail.com"]
  spec.summary = "An easy-to-use and minimal server implementation for the Model Context Protocol (MCP) in Ruby."
  spec.description = "Provides the basics for building MCP servers in Ruby, supporting tools, resources, and prompts."
  spec.homepage = "https://github.com/sergiobayona/MCPRuby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/sergiobayona/MCPRuby"
  spec.metadata["changelog_uri"] = "https://github.com/sergiobayona/MCPRuby/blob/main/CHANGELOG.md"

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler", ">= 2.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
