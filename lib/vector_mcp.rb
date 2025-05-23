# frozen_string_literal: true

# lib/vector_mcp.rb
require "logger"

require_relative "vector_mcp/version"
require_relative "vector_mcp/errors"
require_relative "vector_mcp/definitions"
require_relative "vector_mcp/session"
require_relative "vector_mcp/util"
require_relative "vector_mcp/image_util"
require_relative "vector_mcp/handlers/core"
require_relative "vector_mcp/transport/stdio"
# require_relative "vector_mcp/transport/sse" # Load on demand to avoid async dependencies
require_relative "vector_mcp/server"

# The VectorMCP module provides a full-featured, opinionated Ruby implementation
# of the **Model Context Protocol (MCP)**.  It gives developers everything needed
# to spin up an MCP-compatible server—including:
#
# * **Transport adapters** (synchronous `stdio` or asynchronous HTTP + SSE)
# * **High-level abstractions** for *tools*, *resources*, and *prompts*
# * **JSON-RPC 2.0** message handling with sensible defaults and detailed
#   error reporting helpers
# * A small, dependency-free core (aside from optional async transports) that
#   can be embedded in CLI apps, web servers, or background jobs.
#
# At its simplest you can do:
#
# ```ruby
# require "vector_mcp"
#
# server = VectorMCP.new(name: "my-mcp-server")
# server.register_tool(
#   name: "echo",
#   description: "Echo back the supplied text",
#   input_schema: {type: "object", properties: {text: {type: "string"}}}
# ) { |args| args["text"] }
#
# server.run # => starts the stdio transport and begins processing JSON-RPC messages
# ```
#
# For production you could instead pass an `SSE` transport instance to `run` in
# order to serve multiple concurrent clients over HTTP.
#
module VectorMCP
  # @return [Logger] the shared logger instance for the library.
  @logger = Logger.new($stderr, level: Logger::INFO, progname: "VectorMCP")

  class << self
    # @!attribute [r] logger
    #   @return [Logger] the shared logger instance for the library.
    attr_reader :logger

    # Creates a new {VectorMCP::Server} instance. This is a **thin wrapper** around
    # `VectorMCP::Server.new`; it exists purely for syntactic sugar so you can write
    # `VectorMCP.new` instead of `VectorMCP::Server.new`.
    #
    # Any positional or keyword arguments are forwarded verbatim to the underlying
    # constructor, so refer to {VectorMCP::Server#initialize} for the full list of
    # accepted parameters.
    def new(*args, **kwargs)
      Server.new(*args, **kwargs)
    end
  end
end
