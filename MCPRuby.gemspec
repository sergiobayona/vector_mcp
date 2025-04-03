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

  spec.add_dependency "base64", "~> 0.2"
  spec.add_dependency "eventmachine", "~> 1.2"
  spec.add_dependency "faye-websocket", "~> 0.11"
  spec.add_dependency "json", "~> 2.6"
  spec.add_dependency "logger", "~> 1.5"
  spec.add_dependency "rack", ">= 1", "< 4"
  spec.add_dependency "thin", "~> 1.7"
  spec.add_development_dependency "bundler", ">= 2.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.12"
  spec.add_development_dependency "rubocop", "~> 1.60"
  spec.add_development_dependency "ruby-lsp", "~> 0.1.0"
  spec.metadata["rubygems_mfa_required"] = "true"
end
