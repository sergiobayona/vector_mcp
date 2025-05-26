# frozen_string_literal: true

require "English"
require "logger"
require_relative "definitions"
require_relative "session"
require_relative "errors"
require_relative "transport/stdio" # Default transport
# require_relative "transport/sse" # Load on demand to avoid async dependencies
require_relative "handlers/core" # Default handlers
require_relative "util" # Needed if not using Handlers::Core
require_relative "server/registry"
require_relative "server/capabilities"
require_relative "server/message_handling"

module VectorMCP
  # The `Server` class is the central component for an MCP server implementation.
  # It manages tools, resources, prompts, and handles the MCP message lifecycle.
  #
  # A server instance is typically initialized, configured with capabilities (tools,
  # resources, prompts), and then run with a chosen transport mechanism (e.g., Stdio, SSE).
  #
  # @example Creating and running a simple server
  #   server = VectorMCP::Server.new(name: "MySimpleServer", version: "1.0")
  #
  #   server.register_tool(
  #     name: "echo",
  #     description: "Echoes back the input string.",
  #     input_schema: { type: "object", properties: { message: { type: "string" } } }
  #   ) do |args|
  #     args["message"]
  #   end
  #
  #   server.run(transport: :stdio) # Runs with Stdio transport by default
  #
  # @!attribute [r] logger
  #   @return [Logger] The logger instance for this server.
  # @!attribute [r] name
  #   @return [String] The name of the server.
  # @!attribute [r] version
  #   @return [String] The version of the server software.
  # @!attribute [r] protocol_version
  #   @return [String] The MCP protocol version this server implements.
  # @!attribute [r] tools
  #   @return [Hash<String, VectorMCP::Definitions::Tool>] Registered tools, keyed by name.
  # @!attribute [r] resources
  #   @return [Hash<String, VectorMCP::Definitions::Resource>] Registered resources, keyed by URI string.
  # @!attribute [r] prompts
  #   @return [Hash<String, VectorMCP::Definitions::Prompt>] Registered prompts, keyed by name.
  # @!attribute [r] roots
  #   @return [Hash<String, VectorMCP::Definitions::Root>] Registered roots, keyed by URI string.
  # @!attribute [r] in_flight_requests
  #   @return [Hash] A hash tracking currently processing requests, for cancellation purposes.
  # @!attribute [rw] transport
  #   @return [VectorMCP::Transport::Base, nil] The active transport instance, if any.
  class Server
    include Definitions # Make Tool, Resource, Prompt, Root structs easily available
    include Registry
    include Capabilities
    include MessageHandling

    # The specific version of the Model Context Protocol this server implements.
    PROTOCOL_VERSION = "2024-11-05"

    attr_reader :logger, :name, :version, :protocol_version, :tools, :resources, :prompts, :roots, :in_flight_requests
    attr_accessor :transport

    # Initializes a new VectorMCP server.
    #
    # @param name_pos [String] Positional name argument (deprecated, use name: instead).
    # @param name [String] The name of the server.
    # @param version [String] The version of the server.
    # @param options [Hash] Additional server options:
    #   - :log_level [Integer] The logging level (Logger::DEBUG, Logger::INFO, etc.).
    #   - :protocol_version [String] The MCP protocol version to use.
    #   - :sampling_config [Hash] Configuration for sampling capabilities. Available options:
    #     - :enabled [Boolean] Whether sampling is enabled (default: true)
    #     - :methods [Array<String>] Supported sampling methods (default: ["createMessage"])
    #     - :supports_streaming [Boolean] Whether streaming is supported (default: false)
    #     - :supports_tool_calls [Boolean] Whether tool calls are supported (default: false)
    #     - :supports_images [Boolean] Whether image content is supported (default: false)
    #     - :max_tokens_limit [Integer, nil] Maximum tokens limit (default: nil, no limit)
    #     - :timeout_seconds [Integer] Default timeout for sampling requests (default: 30)
    #     - :context_inclusion_methods [Array<String>] Supported context inclusion methods
    #       (default: ["none", "thisServer"])
    #     - :model_preferences_supported [Boolean] Whether model preferences are supported (default: true)
    def initialize(name_pos = nil, *, name: nil, version: "0.1.0", **options)
      raise ArgumentError, "Name provided both positionally (#{name_pos}) and as keyword argument (#{name})" if name_pos && name && name_pos != name

      @name = name_pos || name || "UnnamedServer"
      @version = version
      @protocol_version = options[:protocol_version] || PROTOCOL_VERSION
      @logger = VectorMCP.logger
      @logger.level = options[:log_level] if options[:log_level]

      @transport = nil
      @tools = {}
      @resources = {}
      @prompts = {}
      @roots = {}
      @request_handlers = {}
      @notification_handlers = {}
      @in_flight_requests = {}
      @prompts_list_changed = false
      @prompt_subscribers = []
      @roots_list_changed = false

      # Configure sampling capabilities
      @sampling_config = configure_sampling_capabilities(options[:sampling_config] || {})

      setup_default_handlers

      @logger.info("Server instance '#{@name}' v#{@version} (MCP Protocol: #{@protocol_version}, Gem: v#{VectorMCP::VERSION}) initialized.")
    end

    # --- Server Execution ---

    # Runs the server using the specified transport mechanism.
    #
    # @param transport [:stdio, :sse, VectorMCP::Transport::Base] The transport to use.
    #   Can be a symbol (`:stdio`, `:sse`) or an initialized transport instance.
    #   If a symbol is provided, the method will instantiate the corresponding transport class.
    #   If `:sse` is chosen, ensure `async` and `falcon` gems are available.
    # @param options [Hash] Transport-specific options (e.g., `:host`, `:port` for SSE).
    #   These are passed to the transport's constructor if a symbol is provided for `transport`.
    # @return [void]
    # @raise [ArgumentError] if an unsupported transport symbol is given.
    # @raise [NotImplementedError] if `:sse` transport is specified (currently a placeholder).
    def run(transport: :stdio, **options)
      active_transport = case transport
                         when :stdio
                           VectorMCP::Transport::Stdio.new(self, **options)
                         when :sse
                           begin
                             require_relative "transport/sse"
                             VectorMCP::Transport::SSE.new(self, **options)
                           rescue LoadError => e
                             logger.fatal("SSE transport requires additional dependencies. Install the 'async' and 'falcon' gems.")
                             raise NotImplementedError, "SSE transport dependencies not available: #{e.message}"
                           end
                         when VectorMCP::Transport::Base # Allow passing an initialized transport instance
                           transport.server = self if transport.respond_to?(:server=) && transport.server.nil? # Ensure server is set
                           transport
                         else
                           logger.fatal("Unsupported transport type: #{transport.inspect}")
                           raise ArgumentError, "Unsupported transport: #{transport.inspect}"
                         end
      self.transport = active_transport
      active_transport.run
    end
  end

  module Transport
    # Dummy base class placeholder used only for argument validation in tests.
    # Real transport classes (e.g., Stdio, SSE) are separate concrete classes.
    class Base # :nodoc:
    end
  end
end
