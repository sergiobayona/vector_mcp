# frozen_string_literal: true

# Add lib directory to load path
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "pry-byebug"
require "vector_mcp"
require "simplecov"
require "simplecov_json_formatter"

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end

SimpleCov.start do
  formatter SimpleCov::Formatter::JSONFormatter
  add_filter "/spec/"
end
