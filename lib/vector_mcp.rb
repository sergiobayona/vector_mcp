# frozen_string_literal: true

# lib/vector_mcp.rb
require "logger"

require_relative "vector_mcp/version"
require_relative "vector_mcp/errors"
require_relative "vector_mcp/definitions"
require_relative "vector_mcp/session"
require_relative "vector_mcp/util"
require_relative "vector_mcp/handlers/core"
require_relative "vector_mcp/transport/stdio"
require_relative "vector_mcp/transport/sse"
require_relative "vector_mcp/server"

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
