# frozen_string_literal: true

require "English"
require "logger"
require_relative "definitions"
require_relative "session"
require_relative "errors"
require_relative "transport/stdio" # Default transport
require_relative "transport/sse"
require_relative "handlers/core" # Default handlers
require_relative "util" # Needed if not using Handlers::Core

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
  # @attr_reader logger [Logger] The logger instance for this server.
  # @attr_reader name [String] The name of the server.
  # @attr_reader version [String] The version of the server software.
  # @attr_reader protocol_version [String] The MCP protocol version this server implements.
  # @attr_reader tools [Hash<String, VectorMCP::Definitions::Tool>] Registered tools, keyed by name.
  # @attr_reader resources [Hash<String, VectorMCP::Definitions::Resource>] Registered resources, keyed by URI string.
  # @attr_reader prompts [Hash<String, VectorMCP::Definitions::Prompt>] Registered prompts, keyed by name.
  # @attr_reader in_flight_requests [Hash] A hash tracking currently processing requests, for cancellation purposes.
  # @attr_accessor transport [VectorMCP::Transport::Base, nil] The active transport instance, if any.
  class Server
    include Definitions # Make Tool, Resource, Prompt structs easily available

    # The specific version of the Model Context Protocol this server implements.
    PROTOCOL_VERSION = "2024-11-05"

    attr_reader :logger, :name, :version, :protocol_version, :tools, :resources, :prompts, :in_flight_requests
    attr_accessor :transport

    # Initializes a new MCP Server.
    #
    # @param name_pos [String, nil] Positional argument for the server name.
    #   Superseded by `name:` keyword if both provided and different.
    # @param name [String] The name of the server (required).
    # @param version [String] The version of this server application (default: "0.1.0").
    # @param log_level [Integer] The logger level (e.g., `Logger::INFO`, `Logger::DEBUG`).
    #   Defaults to `Logger::INFO` via the shared `VectorMCP.logger`.
    # @param protocol_version [String] The MCP protocol version string this server uses
    #   (default: {PROTOCOL_VERSION}).
    # @raise [ArgumentError] if name is not provided or is empty.
    # @raise [ArgumentError] if `name_pos` and `name:` are both provided but differ.
    # rubocop:disable Metrics/ParameterLists
    def initialize(name_pos = nil, *, name: nil, version: "0.1.0", log_level: Logger::INFO, protocol_version: PROTOCOL_VERSION)
      if name_pos && name && name_pos != name
        raise ArgumentError, "Specify the server name either positionally or with the `name:` keyword (not both)."
      end
      @name = name_pos || name
      raise ArgumentError, "Server name is required" if @name.nil? || @name.to_s.strip.empty?

      @version = version
      @protocol_version = protocol_version
      @logger = VectorMCP.logger
      @logger.level = log_level

      @request_handlers = {}
      @notification_handlers = {}
      @tools = {}
      @resources = {}
      @prompts = {}
      @in_flight_requests = {} # For $/cancelRequest
      @prompts_list_changed = false
      @prompt_subscribers = [] # For `notifications/prompts/subscribe`

      setup_default_handlers
      logger.info("Server instance '#{@name}' v#{@version} (MCP Protocol: #{@protocol_version}, Gem: v#{VectorMCP::VERSION}) initialized.")
    end
    # rubocop:enable Metrics/ParameterLists

    # --- Registration Methods ---

    # Registers a new tool with the server.
    #
    # @param name [String, Symbol] The unique name for the tool.
    # @param description [String] A human-readable description of the tool.
    # @param input_schema [Hash] A JSON Schema definition for the tool's input parameters.
    # @yield [Hash] A block that implements the tool's logic. It receives a hash of arguments
    #   conforming to `input_schema` and should return the tool's output.
    # @return [self] The server instance, allowing for method chaining.
    # @raise [ArgumentError] if a tool with the same name is already registered.
    def register_tool(name:, description:, input_schema:, &handler)
      name_s = name.to_s
      raise ArgumentError, "Tool '#{name_s}' already registered" if @tools[name_s]
      @tools[name_s] = Tool.new(name_s, description, input_schema, handler)
      logger.debug("Registered tool: #{name_s}")
      self
    end

    # Registers a new resource with the server.
    #
    # @param uri [String, URI] The unique URI for the resource.
    # @param name [String] A human-readable name for the resource.
    # @param description [String] A description of the resource.
    # @param mime_type [String] The MIME type of the resource's content (default: "text/plain").
    # @yield [Hash] A block that provides the resource's content. It may receive parameters
    #   from the `resources/read` request (though often unused for simple resources).
    # @return [self] The server instance, for chaining.
    # @raise [ArgumentError] if a resource with the same URI is already registered.
    def register_resource(uri:, name:, description:, mime_type: "text/plain", &handler)
      uri_s = uri.to_s
      raise ArgumentError, "Resource '#{uri_s}' already registered" if @resources[uri_s]
      @resources[uri_s] = Resource.new(uri, name, description, mime_type, handler)
      logger.debug("Registered resource: #{uri_s}")
      self
    end

    # Registers a new prompt with the server.
    #
    # @param name [String, Symbol] The unique name for the prompt.
    # @param description [String] A human-readable description of the prompt.
    # @param arguments [Array<Hash>] An array defining the prompt's arguments.
    #   Each hash should conform to the prompt argument schema (e.g., `{ name:, description:, required: }`).
    # @yield [Hash] A block that generates the prompt. It receives a hash of arguments
    #   supplied by the client, validated against the `arguments` definition.
    # @return [self] The server instance, for chaining.
    # @raise [ArgumentError] if a prompt with the same name is already registered, or if
    #   the `arguments` definition is invalid.
    def register_prompt(name:, description:, arguments: [], &handler)
      name_s = name.to_s
      raise ArgumentError, "Prompt '#{name_s}' already registered" if @prompts[name_s]
      validate_prompt_arguments(arguments)
      @prompts[name_s] = Prompt.new(name_s, description, arguments, handler)
      @prompts_list_changed = true
      notify_prompts_list_changed
      logger.debug("Registered prompt: #{name_s}")
      self
    end

    # --- Request/Notification Hook Methods ---

    # Registers a handler for a specific JSON-RPC request method.
    #
    # @param method [String, Symbol] The method name (e.g., "my/customMethod").
    # @yield [params, session, server] A block to handle the request.
    #   - `params` [Hash]: The request parameters.
    #   - `session` [VectorMCP::Session]: The current client session.
    #   - `server` [VectorMCP::Server]: The server instance itself.
    #   The block should return the result for the JSON-RPC response.
    # @return [self] The server instance.
    def on_request(method, &handler)
      @request_handlers[method.to_s] = handler
      self
    end

    # Registers a handler for a specific JSON-RPC notification method.
    #
    # @param method [String, Symbol] The method name (e.g., "my/customNotification").
    # @yield [params, session, server] A block to handle the notification.
    #   (Parameters are the same as for `on_request`.)
    # @return [self] The server instance.
    def on_notification(method, &handler)
      @notification_handlers[method.to_s] = handler
      self
    end

    # --- Server Execution ---

    # Runs the server using the specified transport mechanism.
    #
    # @param transport [:stdio, :sse, VectorMCP::Transport::Base] The transport to use.
    #   Can be a symbol (`:stdio`, `:sse`) or an initialized transport instance.
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
                           # VectorMCP::Transport::SSE.new(self, **options)
                           raise NotImplementedError, "The SSE transport is not yet production-ready. Use with caution or provide an instance."
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

    # --- Message Handling Logic (primarily called by transports) ---

    # Handles an incoming JSON-RPC message (request or notification).
    # This is the main dispatch point for messages received by a transport.
    #
    # @param message [Hash] The parsed JSON-RPC message object.
    # @param session [VectorMCP::Session] The client session associated with this message.
    # @param session_id [String] A unique identifier for the underlying transport connection (e.g., socket ID, stdio pipe).
    # @return [Object, nil] For requests, returns the result data to be sent in the JSON-RPC response.
    #   For notifications, returns `nil`.
    # @raise [VectorMCP::ProtocolError] if the message is invalid or an error occurs during handling
    #   that should be reported as a JSON-RPC error.
    def handle_message(message, session, session_id)
      id = message["id"]
      method = message["method"]
      params = message["params"] || {} # Default to empty hash if params is nil

      if id && method # Request
        logger.info("[#{session_id}] Request [#{id}]: #{method} with params: #{params.inspect}")
        handle_request(id, method, params, session)
      elsif method # Notification
        logger.info("[#{session_id}] Notification: #{method} with params: #{params.inspect}")
        handle_notification(method, params, session)
        nil # Notifications do not have a return value to send back to client
      elsif id # Invalid: Has ID but no method (likely a malformed request or client sending a response)
        logger.warn("[#{session_id}] Invalid message: Has ID [#{id}] but no method. #{message.inspect}")
        raise VectorMCP::InvalidRequestError.new("Request object must include a 'method' member.", request_id: id)
      else # Invalid: No ID and no method
        logger.warn("[#{session_id}] Invalid message: Missing both 'id' and 'method'. #{message.inspect}")
        raise VectorMCP::InvalidRequestError.new("Message must be a request (with id and method) or notification (with method).", request_id: nil)
      end
    end

    # --- Server Information and Capabilities ---

    # Provides basic information about the server.
    # @return [Hash] Server name and version.
    def server_info
      { name: @name, version: @version }
    end

    # Describes the capabilities of this server according to MCP specifications.
    # @return [Hash] A capabilities object.
    def server_capabilities
      caps = {}
      caps[:tools] = { listChanged: false } unless @tools.empty? # `listChanged` for tools is not standard but included for symmetry
      caps[:resources] = { subscribe: false, listChanged: false } unless @resources.empty?
      caps[:prompts] = { listChanged: @prompts_list_changed } unless @prompts.empty?
      # `experimental` is a defined field in MCP capabilities, can be used for non-standard features.
      caps[:experimental] = {}
      caps
    end

    # Resets the `prompts_list_changed` flag to false.
    # Typically called by the `prompts/list` handler after a client has fetched the updated list.
    # @return [void]
    def clear_prompts_list_changed
      @prompts_list_changed = false
      logger.debug("Prompts listChanged flag cleared.")
    end

    # Notifies connected clients that the list of available prompts has changed.
    # This method attempts to use `broadcast_notification` if the transport supports it,
    # otherwise falls back to `send_notification` (which might only make sense for single-client transports like stdio).
    # @return [void]
    def notify_prompts_list_changed
      return unless transport && @prompts_list_changed # Only notify if there was a change and transport is up

      notification_method = "notifications/prompts/listChanged" # Corrected method name
      begin
        if transport.respond_to?(:broadcast_notification)
          logger.info("Broadcasting prompts list changed notification.")
          transport.broadcast_notification(notification_method)
        elsif transport.respond_to?(:send_notification)
          # For single-client transports or as a fallback if broadcast isn't specific
          logger.info("Sending prompts list changed notification (transport may broadcast or send to first client).")
          transport.send_notification(notification_method) # Transport needs to decide target if not broadcast
        else
          logger.warn("Transport does not support sending notifications/prompts/listChanged.")
        end
      rescue StandardError => e
        logger.error("Failed to send prompts list changed notification: #{e.class.name}: #{e.message}")
      end
    end

    private

    # Registers a session as a subscriber to prompt list changes.
    # Used by the `prompts/subscribe` handler.
    # @api private
    # @param session [VectorMCP::Session] The session to subscribe.
    # @return [void]
    def subscribe_prompts(session)
      @prompt_subscribers << session unless @prompt_subscribers.include?(session)
      logger.debug("Session subscribed to prompt list changes: #{session.object_id}")
    end

    # Internal handler for JSON-RPC requests.
    # @api private
    # @param id [String, Integer] The request ID.
    # @param method [String] The request method name.
    # @param params [Hash] The request parameters.
    # @param session [VectorMCP::Session] The client session.
    # @return [Object] The result of the request handler.
    # @raise [VectorMCP::ProtocolError] Propagates errors from handlers or raises new ones (e.g., MethodNotFound).
    def handle_request(id, method, params, session)
      unless session.initialized?
        # Allow "initialize" even if not marked initialized yet by server
        return session.initialize!(params) if method == "initialize"
        # For any other method, session must be initialized
        raise VectorMCP::InitializationError.new("Session not initialized. Client must send 'initialize' first.", request_id: id)
      end

      handler = @request_handlers[method]
      raise VectorMCP::MethodNotFoundError.new(method, request_id: id) unless handler

      begin
        @in_flight_requests[id] = { method: method, params: params, session: session, start_time: Time.now }
        result = handler.call(params, session, self)
        result
      rescue VectorMCP::ProtocolError => e # Includes NotFoundError, InvalidParamsError, InternalError from handlers
        # Ensure the request ID from the current context is on the error
        e.request_id = id unless e.request_id && e.request_id == id
        raise e # Re-raise with potentially updated request_id
      rescue StandardError => e
        logger.error("Unhandled error in '#{method}' request handler (ID: #{id}): #{e.class.name} - #{e.message}\nBacktrace: #{e.backtrace.join("\n  ")}")
        raise VectorMCP::InternalError.new(
          "Request handler for '#{method}' failed unexpectedly.",
          request_id: id,
          details: { original_error: e.class.name, method: method }
        )
      ensure
        @in_flight_requests.delete(id)
      end
    end

    # Internal handler for JSON-RPC notifications.
    # @api private
    # @param method [String] The notification method name.
    # @param params [Hash] The notification parameters.
    # @param session [VectorMCP::Session] The client session.
    # @return [void]
    def handle_notification(method, params, session)
      unless session.initialized? || method == "initialized"
        logger.warn("Ignoring notification '#{method}' before session is initialized. Params: #{params.inspect}")
        return
      end

      handler = @notification_handlers[method]
      if handler
        begin
          handler.call(params, session, self)
        rescue StandardError => e
          logger.error("Error in '#{method}' notification handler: #{e.class.name} - #{e.message}\nBacktrace (top 5):\n  #{e.backtrace.first(5).join("\n  ")}")
          # Notifications must not generate a response, even on error.
        end
      else
        logger.debug("No handler registered for notification: #{method}")
      end
    end

    # Sets up default handlers for core MCP methods using {VectorMCP::Handlers::Core}.
    # @api private
    # @return [void]
    def setup_default_handlers
      # Core Requests
      on_request("initialize", &session_method(:initialize!))
      on_request("ping", &Handlers::Core.method(:ping))
      on_request("tools/list", &Handlers::Core.method(:list_tools))
      on_request("tools/call", &Handlers::Core.method(:call_tool))
      on_request("resources/list", &Handlers::Core.method(:list_resources))
      on_request("resources/read", &Handlers::Core.method(:read_resource))
      on_request("prompts/list", &Handlers::Core.method(:list_prompts))
      on_request("prompts/get", &Handlers::Core.method(:get_prompt))
      on_request("prompts/subscribe", &Handlers::Core.method(:subscribe_prompts))

      # Core Notifications
      on_notification("initialized", &Handlers::Core.method(:initialized_notification))
      # Standard cancel request names
      %w[$/cancelRequest $/cancel notifications/cancelled].each do |cancel_method|
        on_notification(cancel_method, &Handlers::Core.method(:cancel_request_notification))
      end
    end

    # Helper to create a proc that calls a method on the session object.
    # Used for the `initialize` request handler.
    # @api private
    def session_method(method_name)
      lambda do |params, session, _server|
        session.public_send(method_name, params)
      end
    end

    # Validates the structure of the `arguments` array provided to {#register_prompt}.
    # Each item must be a Hash with at least a `:name`, and optionally `:description` and `:required`.
    # @api private
    # @param argument_defs [Array<Hash>] The array of argument definitions to validate.
    # @return [void]
    # @raise [ArgumentError] if `argument_defs` is not an Array or if any definition is invalid.
    def validate_prompt_arguments(argument_defs)
      raise ArgumentError, "Prompt arguments definition must be an Array of Hashes." unless argument_defs.is_a?(Array)
      argument_defs.each_with_index { |arg, idx| validate_single_prompt_argument(arg, idx) }
    end

    # Defines the keys allowed in a prompt argument definition hash.
    ALLOWED_PROMPT_ARG_KEYS = %w[name description required type].freeze # Added 'type' as per common usage
    private_constant :ALLOWED_PROMPT_ARG_KEYS

    # Validates a single prompt argument definition hash.
    # @api private
    # @param arg [Hash] The argument definition hash.
    # @param idx [Integer] The index of this argument in the list (for error messages).
    # @return [void]
    # @raise [ArgumentError] if the argument definition is invalid.
    def validate_single_prompt_argument(arg, idx)
      unless arg.is_a?(Hash)
        raise ArgumentError, "Prompt argument definition at index #{idx} must be a Hash. Found: #{arg.class}"
      end

      validate_prompt_arg_name!(arg, idx)
      validate_prompt_arg_description!(arg, idx)
      validate_prompt_arg_required_flag!(arg, idx)
      validate_prompt_arg_type!(arg, idx) # New validation for :type
      validate_prompt_arg_unknown_keys!(arg, idx)
    end

    # Validates the :name key of a prompt argument definition.
    # @api private
    def validate_prompt_arg_name!(arg, idx)
      name_val = arg[:name] || arg["name"]
      raise ArgumentError, "Prompt argument at index #{idx} is missing a :name." if name_val.nil?
      unless name_val.is_a?(String) || name_val.is_a?(Symbol)
        raise ArgumentError, "Prompt argument :name at index #{idx} must be a String or Symbol. Found: #{name_val.class}"
      end
      raise ArgumentError, "Prompt argument :name at index #{idx} cannot be empty." if name_val.to_s.strip.empty?
    end

    # Validates the :description key of a prompt argument definition.
    # @api private
    def validate_prompt_arg_description!(arg, idx)
      return unless arg.key?(:description) || arg.key?("description") # Optional field
      desc_val = arg[:description] || arg["description"]
      return if desc_val.nil? || desc_val.is_a?(String) # Allow nil or String
      raise ArgumentError, "Prompt argument :description at index #{idx} must be a String if provided. Found: #{desc_val.class}"
    end

    # Validates the :required key of a prompt argument definition.
    # @api private
    def validate_prompt_arg_required_flag!(arg, idx)
      return unless arg.key?(:required) || arg.key?("required") # Optional field
      req_val = arg[:required] || arg["required"]
      return if [true, false].include?(req_val)
      raise ArgumentError, "Prompt argument :required at index #{idx} must be true or false if provided. Found: #{req_val.inspect}"
    end

    # Validates the :type key of a prompt argument definition (new).
    # @api private
    def validate_prompt_arg_type!(arg, idx)
      return unless arg.key?(:type) || arg.key?("type") # Optional field
      type_val = arg[:type] || arg["type"]
      return if type_val.nil? || type_val.is_a?(String) # Allow nil or String (e.g., "string", "number", "boolean")
      raise ArgumentError, "Prompt argument :type at index #{idx} must be a String if provided (e.g., JSON schema type). Found: #{type_val.class}"
    end

    # Checks for any unknown keys in a prompt argument definition.
    # @api private
    def validate_prompt_arg_unknown_keys!(arg, idx)
      unknown_keys = arg.transform_keys(&:to_s).keys - ALLOWED_PROMPT_ARG_KEYS
      return if unknown_keys.empty?
      raise ArgumentError, "Prompt argument definition at index #{idx} contains unknown keys: #{unknown_keys.join(", ")}. Allowed: #{ALLOWED_PROMPT_ARG_KEYS.join(", ")}."
    end
  end
end
