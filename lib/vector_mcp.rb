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

# The VectorMCP module provides a Ruby implementation of the Model Context Protocol.
# It allows for building servers that can communicate with MCP clients,
# offering resources, tools, and prompts.
module VectorMCP
  # @return [Logger] the shared logger instance for the library.
  @logger = Logger.new($stderr, level: Logger::INFO, progname: "VectorMCP")

  class << self
    # @!attribute [r] logger
    #   @return [Logger] the shared logger instance for the library.
    attr_reader :logger

    # Creates a new VectorMCP::Server instance.
    # This is a convenience method that delegates to {VectorMCP::Server.new}.
    #
    # @param args [Array] arguments to pass to the Server constructor.
    # @param kwargs [Hash] keyword arguments to pass to the Server constructor.
    # @return [VectorMCP::Server] a new server instance.
    def new(*args, **kwargs)
      Server.new(*args, **kwargs)
    end
  end
end
