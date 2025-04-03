# frozen_string_literal: true

# lib/mcp_ruby.rb
require "logger"

require_relative "mcp_ruby/version"
require_relative "mcp_ruby/errors"
require_relative "mcp_ruby/definitions"
require_relative "mcp_ruby/session"
require_relative "mcp_ruby/util"
require_relative "mcp_ruby/handlers/core"
require_relative "mcp_ruby/transport/stdio"
require_relative "mcp_ruby/server"

module MCPRuby
  # Shared logger instance for the library
  @logger = Logger.new($stderr, level: Logger::INFO, progname: "MCPRuby")

  class << self
    attr_accessor :logger
  end

  # Convenience method to create a server instance
  def self.new_server(**options)
    Server.new(**options)
  end
end
