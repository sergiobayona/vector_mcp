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
require_relative "mcp_ruby/transport/sse"
require_relative "mcp_ruby/server"

module VectorMCP
  # Shared logger instance for the library
  @logger = Logger.new($stderr, level: Logger::INFO, progname: "VectorMCP")

  class << self
    attr_reader :logger

    # Convenience method to create a server instance
    def new_server(**kwargs)
      Server.new(**kwargs)
    end
  end
end
