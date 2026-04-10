# frozen_string_literal: true

require "English"
require "logger"
require_relative "definitions"
require_relative "session"
require_relative "errors"
require_relative "handlers/core" # Default handlers
require_relative "util" # Needed if not using Handlers::Core
require_relative "server/registry"
require_relative "server/capabilities"
require_relative "server/message_handling"
require_relative "security/auth_manager"
require_relative "security/authorization"
require_relative "security/middleware"
require_relative "security/session_context"
require_relative "security/strategies/api_key"
require_relative "security/strategies/jwt_token"
require_relative "security/strategies/custom"
require_relative "middleware"

module VectorMCP
  # The `Server` class is the central component for an MCP server implementation.
  # It manages tools, resources, prompts, and handles the MCP message lifecycle.
  #
  # A server instance is typically initialized, configured with capabilities (tools,
  # resources, prompts), and then run with a chosen transport mechanism (e.g., HttpStream).
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
  #   server.run # Runs with HttpStream transport by default
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
    PROTOCOL_VERSION = "2025-11-25"

    # All protocol versions this server accepts via the MCP-Protocol-Version header.
    SUPPORTED_PROTOCOL_VERSIONS = %w[2025-11-25 2025-03-26 2024-11-05].freeze

    attr_reader :logger, :name, :version, :protocol_version, :tools, :resources, :prompts, :roots, :in_flight_requests,
                :auth_manager, :authorization, :security_middleware, :middleware_manager, :oauth_resource_metadata_url
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
      @logger = VectorMCP.logger_for("server")
      # NOTE: log level should be configured via VectorMCP.configure_logging instead

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

      # Initialize security components
      @auth_manager = Security::AuthManager.new
      @authorization = Security::Authorization.new
      @security_middleware = Security::Middleware.new(@auth_manager, @authorization)
      @oauth_resource_metadata_url = nil

      # Initialize middleware manager
      @middleware_manager = Middleware::Manager.new

      setup_default_handlers

      @logger.info("Server instance '#{@name}' v#{@version} (MCP Protocol: #{@protocol_version}, Gem: v#{VectorMCP::VERSION}) initialized.")
    end

    # --- Server Execution ---

    # Runs the server using the specified transport mechanism.
    #
    # @param transport [:http_stream, VectorMCP::Transport::Base] The transport to use.
    #   Can be the symbol `:http_stream` or an initialized transport instance.
    #   If `:http_stream` is provided, the method will instantiate the MCP-compliant streamable HTTP transport.
    # @param options [Hash] Transport-specific options (e.g., `:host`, `:port`).
    #   These are passed to the transport's constructor if a symbol is provided for `transport`.
    # @return [void]
    # @raise [ArgumentError] if an unsupported transport symbol is given.
    def run(transport: :http_stream, **)
      active_transport = case transport
                         when :http_stream
                           begin
                             require_relative "transport/http_stream"
                             VectorMCP::Transport::HttpStream.new(self, **)
                           rescue LoadError => e
                             logger.fatal("HttpStream transport requires additional dependencies.")
                             raise NotImplementedError, "HttpStream transport dependencies not available: #{e.message}"
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

    # Returns the MCP server as a Rack application suitable for mounting inside
    # another Rack-based framework (e.g., Rails, Sinatra).
    #
    # Unlike {#run}, this method does NOT start its own HTTP server or block.
    # The returned object responds to `#call(env)` and can be mounted directly:
    #
    #   # config/routes.rb (Rails)
    #   mount MCP_APP => "/mcp"
    #
    # Call `server.transport.stop` on application shutdown to clean up resources.
    #
    # @param options [Hash] Transport options (e.g., :session_timeout, :event_retention, :allowed_origins)
    # @return [VectorMCP::Transport::HttpStream] A Rack-compatible app
    def rack_app(**)
      require_relative "transport/http_stream"
      active_transport = VectorMCP::Transport::HttpStream.new(self, mounted: true, **)
      self.transport = active_transport
      active_transport
    end

    # --- Security Configuration ---

    # Enable authentication with specified strategy and configuration
    # @param strategy [Symbol] the authentication strategy (:api_key, :jwt, :custom)
    # @param options [Hash] strategy-specific configuration options
    # @option options [String] :resource_metadata_url OAuth 2.1 protected resource metadata URL
    #   (RFC 9728). When provided, unauthenticated requests to the HTTP Stream transport's MCP
    #   endpoint return HTTP 401 with a +WWW-Authenticate: Bearer+ header pointing at this URL,
    #   enabling MCP clients (e.g. Claude Desktop) to discover the authorization server and
    #   initiate an OAuth 2.1 flow. When omitted (default), auth failures continue to surface
    #   as JSON-RPC +-32401+ errors — existing behavior is preserved for non-OAuth deployments.
    # @return [void]
    def enable_authentication!(strategy: :api_key, **options, &block)
      # Clear existing strategies when switching to a new configuration
      clear_auth_strategies unless @auth_manager.strategies.empty?

      # Extract OAuth resource metadata URL before forwarding options to strategy constructors
      @oauth_resource_metadata_url = options.delete(:resource_metadata_url)
      warn_on_insecure_oauth_metadata_url(@oauth_resource_metadata_url)

      @auth_manager.enable!(default_strategy: strategy)

      case strategy
      when :api_key
        add_api_key_auth(options[:keys] || [], allow_query_params: options[:allow_query_params] || false)
      when :jwt
        add_jwt_auth(options)
      when :custom
        handler = block || options[:handler]
        raise ArgumentError, "Custom authentication strategy requires a handler block" unless handler

        add_custom_auth(&handler)

      else
        raise ArgumentError, "Unknown authentication strategy: #{strategy}"
      end

      @logger.info("Authentication enabled with strategy: #{strategy}")
    end

    # Disable authentication (return to pass-through mode)
    # @return [void]
    def disable_authentication!
      @auth_manager.disable!
      @oauth_resource_metadata_url = nil
      @logger.info("Authentication disabled")
    end

    # Enable authorization with optional policy configuration block
    # @param block [Proc] optional block for configuring authorization policies
    # @return [void]
    def enable_authorization!(&)
      @authorization.enable!
      instance_eval(&) if block_given?
      @logger.info("Authorization enabled")
    end

    # Disable authorization (return to pass-through mode)
    # @return [void]
    def disable_authorization!
      @authorization.disable!
      @logger.info("Authorization disabled")
    end

    # Add authorization policy for tools
    # @param block [Proc] policy block that receives (user, action, tool)
    # @return [void]
    def authorize_tools(&)
      @authorization.add_policy(:tool, &)
    end

    # Add authorization policy for resources
    # @param block [Proc] policy block that receives (user, action, resource)
    # @return [void]
    def authorize_resources(&)
      @authorization.add_policy(:resource, &)
    end

    # Add authorization policy for prompts
    # @param block [Proc] policy block that receives (user, action, prompt)
    # @return [void]
    def authorize_prompts(&)
      @authorization.add_policy(:prompt, &)
    end

    # Add authorization policy for roots
    # @param block [Proc] policy block that receives (user, action, root)
    # @return [void]
    def authorize_roots(&)
      @authorization.add_policy(:root, &)
    end

    # Check if security features are enabled
    # @return [Boolean] true if authentication or authorization is enabled
    def security_enabled?
      @security_middleware.security_enabled?
    end

    # Get current security status for debugging/monitoring
    # @return [Hash] security configuration status
    def security_status
      @security_middleware.security_status
    end

    # --- Middleware Management ---

    # Register middleware for specific hook types
    # @param middleware_class [Class] Middleware class inheriting from VectorMCP::Middleware::Base
    # @param hooks [Symbol, Array<Symbol>] Hook types to register for (e.g., :before_tool_call, [:before_tool_call, :after_tool_call])
    # @param priority [Integer] Execution priority (lower numbers execute first, default: 100)
    # @param conditions [Hash] Conditions for when middleware should run
    # @option conditions [Array<String>] :only_operations Only run for these operations
    # @option conditions [Array<String>] :except_operations Don't run for these operations
    # @option conditions [Array<String>] :only_users Only run for these user IDs
    # @option conditions [Array<String>] :except_users Don't run for these user IDs
    # @option conditions [Boolean] :critical If true, errors in this middleware stop execution
    # @example
    #   server.use_middleware(MyMiddleware, :before_tool_call)
    #   server.use_middleware(AuthMiddleware, [:before_request, :after_response], priority: 10)
    #   server.use_middleware(LoggingMiddleware, :after_tool_call, conditions: { only_operations: ['important_tool'] })
    def use_middleware(middleware_class, hooks, priority: Middleware::Hook::DEFAULT_PRIORITY, conditions: {})
      @middleware_manager.register(middleware_class, hooks, priority: priority, conditions: conditions)
      @logger.debug("Registered middleware: #{middleware_class.name}")
    end

    # Remove all middleware hooks for a specific class
    # @param middleware_class [Class] Middleware class to remove
    def remove_middleware(middleware_class)
      @middleware_manager.unregister(middleware_class)
      @logger.debug("Removed middleware: #{middleware_class.name}")
    end

    # Get middleware statistics
    # @return [Hash] Statistics about registered middleware
    def middleware_stats
      @middleware_manager.stats
    end

    # Clear all middleware (useful for testing)
    def clear_middleware!
      @middleware_manager.clear!
      @logger.debug("Cleared all middleware")
    end

    private

    # Add API key authentication strategy
    # @param keys [Array<String>] array of valid API keys
    # @param allow_query_params [Boolean] whether to accept API keys from query parameters
    # @return [void]
    def add_api_key_auth(keys, allow_query_params: false)
      strategy = Security::Strategies::ApiKey.new(keys: keys, allow_query_params: allow_query_params)
      @auth_manager.add_strategy(:api_key, strategy)
    end

    # Add JWT authentication strategy
    # @param options [Hash] JWT configuration options
    # @return [void]
    def add_jwt_auth(options)
      strategy = Security::Strategies::JwtToken.new(**options)
      @auth_manager.add_strategy(:jwt, strategy)
    end

    # Add custom authentication strategy
    # @param handler [Proc] custom authentication handler block
    # @return [void]
    def add_custom_auth(&)
      strategy = Security::Strategies::Custom.new(&)
      @auth_manager.add_strategy(:custom, strategy)
    end

    # Clear all authentication strategies
    # @return [void]
    def clear_auth_strategies
      @auth_manager.strategies.each_key do |strategy_name|
        @auth_manager.remove_strategy(strategy_name)
      end
    end

    # Emit a warning when the OAuth resource metadata URL is not HTTPS.
    # We don't raise because local development against http://localhost is a valid use case.
    # @param url [String, nil] the configured metadata URL
    # @return [void]
    def warn_on_insecure_oauth_metadata_url(url)
      return if url.nil?
      return if url.start_with?("https://")

      @logger.warn do
        "[SECURITY] resource_metadata_url is not HTTPS (#{url}). " \
          "Use HTTPS in production; plaintext is only acceptable for local development."
      end
    end
  end

  module Transport
    # Dummy base class placeholder used only for argument validation in tests.
    # Real transport classes (e.g., HttpStream) are separate concrete classes.
    class Base # :nodoc:
    end
  end
end
