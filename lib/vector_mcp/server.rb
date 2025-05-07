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
  # Central class for the MCP Server implementation.
  class Server
    include Definitions # Make Tool, Resource, Prompt structs easily available

    PROTOCOL_VERSION = "2024-11-05"

    attr_reader :logger, :name, :version, :protocol_version, :tools, :resources, :prompts, :in_flight_requests
    attr_accessor :transport

    def initialize(name:, version: "0.1.0", log_level: Logger::INFO, protocol_version: PROTOCOL_VERSION)
      @name = name
      @version = version
      @protocol_version = protocol_version
      @logger = VectorMCP.logger # Use the shared logger instance
      @logger.level = log_level

      @request_handlers = {}
      @notification_handlers = {}
      @tools = {}
      @resources = {}
      @prompts = {}
      @in_flight_requests = {} # Track requests for cancellation
      @prompts_list_changed = false # Track whether prompts list changed after initialization
      @prompt_subscribers = []

      setup_default_handlers
      logger.info("Server instance '#{name}' v#{version} (using VectorMCP v#{VectorMCP::VERSION}) initialized.")
    end

    # --- Registration Methods ---

    def register_tool(name:, description:, input_schema:, &handler)
      name_s = name.to_s
      raise ArgumentError, "Tool '#{name_s}' already registered" if @tools[name_s]

      @tools[name_s] = Tool.new(name_s, description, input_schema, handler)
      logger.debug("Registered tool: #{name_s}")
      self # Allow chaining
    end

    def register_resource(uri:, name:, description:, mime_type: "text/plain", &handler)
      uri_s = uri.to_s
      raise ArgumentError, "Resource '#{uri_s}' already registered" if @resources[uri_s]

      @resources[uri_s] = Resource.new(uri, name, description, mime_type, handler)
      logger.debug("Registered resource: #{uri_s}")
      self
    end

    def register_prompt(name:, description:, arguments: [], &handler)
      name_s = name.to_s
      raise ArgumentError, "Prompt '#{name_s}' already registered" if @prompts[name_s]

      # Validate arguments schema fidelity
      validate_prompt_arguments(arguments)

      @prompts[name_s] = Prompt.new(name_s, description, arguments, handler)
      # Mark the prompts list as changed so clients know to refresh
      @prompts_list_changed = true
      # If a transport is active, proactively notify clients about the list change.
      notify_prompts_list_changed
      logger.debug("Registered prompt: #{name_s}")
      self
    end

    # --- Request/Notification Hook Methods ---

    def on_request(method, &handler)
      @request_handlers[method.to_s] = handler
      self
    end

    def on_notification(method, &handler)
      @notification_handlers[method.to_s] = handler
      self
    end

    # --- Server Execution ---

    def run(transport: :stdio, options: {})
      case transport
      when :stdio
        transport_instance = VectorMCP::Transport::Stdio.new(self)
        self.transport = transport_instance
        transport_instance.run
      when :sse
        # The SSE transport is not production-ready yet.
        # Raise a clear error so callers know it cannot be used for now.
        raise NotImplementedError, "The SSE transport is not yet supported."
      else
        logger.fatal("Unsupported transport: #{transport}")
        raise ArgumentError, "Unsupported transport: #{transport}"
      end
    end

    # --- Message Handling Logic (called by transport) ---
    # Now returns the result/error hash, transport handles sending
    # Added session_id for context if needed, though not used in core handlers yet
    def handle_message(message, session, session_id)
      id = message["id"]
      method = message["method"]
      params = message["params"] || {} # Ensure params is always a hash

      if id && method # It's a request
        logger.info("[#{session_id}] Received request [#{id}]: #{method}")
        handle_request(id, method, params, session) # Removed transport
      elsif method # It's a notification
        logger.info("[#{session_id}] Received notification: #{method}")
        handle_notification(method, params, session) # Removed transport
        nil # Notifications don't return a value to send back
      elsif id # It's a response (client shouldn't send these) OR an invalid request with ID but no method
        # JSON-RPC spec says: "If there was an error in detecting the id in the Request object (e.g. Parse error/Invalid Request), it MUST be Null."
        # However, it also says an error object MUST be included for Invalid Request. We prioritize sending an error.
        logger.warn("[#{session_id}] Received message with id [#{id}] but no method. Treating as Invalid Request.")
        raise VectorMCP::InvalidRequestError.new("Request object must include a 'method' member", request_id: id)
      else # Invalid message (no id, no method)
        raise VectorMCP::InvalidRequestError, "Invalid message format: #{message.inspect}"
      end
    end

    # --- Server Capabilities ---
    def server_info
      { name: @name, version: @version }
    end

    def server_capabilities
      caps = {}
      caps[:tools] = { listChanged: false } unless @tools.empty?
      caps[:resources] = { subscribe: false, listChanged: false } unless @resources.empty?
      caps[:prompts] = { listChanged: @prompts_list_changed } unless @prompts.empty?
      caps[:experimental] = {}
      caps
    end

    # Clear the prompts listChanged flag (typically called after a client refreshes the list)
    def clear_prompts_list_changed
      @prompts_list_changed = false
    end

    def notify_prompts_list_changed
      return unless transport

      if transport.respond_to?(:broadcast_notification)
        transport.broadcast_notification("notifications/prompts/list_changed")
      elsif transport.respond_to?(:send_notification)
        transport.send_notification("notifications/prompts/list_changed")
      end
    rescue StandardError => e
      logger.error("Failed to send prompts list changed notification: #{e.message}")
    end

    private

    # Allow Core handler to register a session as subscriber
    def subscribe_prompts(session)
      @prompt_subscribers << session unless @prompt_subscribers.include?(session)
    end

    # Returns the result hash or raises a ProtocolError
    def handle_request(id, method, params, session)
      unless session.initialized?
        raise VectorMCP::InitializationError.new(request_id: id) unless method == "initialize"

        # Handle initialize request specifically (Session#initialize! already returns the result hash)
        return session.initialize!(params)
      end

      handler = @request_handlers[method]
      raise VectorMCP::MethodNotFoundError.new(method, request_id: id) unless handler

      begin
        # Track request *start* - response handled by caller now
        @in_flight_requests[id] = { method: method, params: params, session: session }
        # Pass params, session, and server instance to the handler
        # Handler is expected to return the result hash
        result = handler.call(params, session, self)
        result # Return the result hash
      # Re-raise known protocol errors to be handled by caller
      # Note: InternalError raised *explicitly* within handlers (e.g. for invalid structure)
      # will also be caught here and re-raised.
      rescue VectorMCP::NotFoundError, VectorMCP::InvalidParamsError, VectorMCP::InternalError
        # Ensure request_id is attached if missing (though usually set at source)
        raise $ERROR_INFO if $ERROR_INFO.request_id == id

        raise $ERROR_INFO.class.new($ERROR_INFO.message, details: $ERROR_INFO.details, request_id: id)
      rescue StandardError => e
        # Log the detailed error for server-side debugging
        logger.error("Unhandled error during request '#{method}' (ID: #{id}): #{e.message}\n#{e.backtrace.join("\n")}")
        # Wrap unexpected errors (like those from handlers) in InternalError, including the request_id
        raise VectorMCP::InternalError.new("Request handler failed unexpectedly", request_id: id,
                                                                                  details: { method: method, error: "An internal error occurred" })
      ensure
        # Still remove tracking *after* handler execution (success or raise)
        @in_flight_requests.delete(id)
      end
    end

    def handle_notification(method, params, session)
      # Special handling for 'initialized' is now within the handler itself
      unless session.initialized? && method != "initialized"
        # Allow 'initialized' even if session state isn't formally true yet on server-side
        logger.warn("Ignoring notification '#{method}' before initialization complete") unless method == "initialized"
        return if method != "initialized"
      end

      handler = @notification_handlers[method]
      if handler
        begin
          handler.call(params, session, self)
        rescue StandardError => e
          # Cannot send an error response for a notification
          logger.error("Error executing notification handler '#{method}': #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        end
      else
        logger.debug("No handler for notification: #{method}")
      end
    end

    # Sets up the default handlers using the Handlers::Core module
    def setup_default_handlers
      # Core Requests
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
      # Handle multiple potential names for cancellation
      %w[$/cancelRequest $/cancel notifications/cancelled].each do |cancel_method|
        on_notification(cancel_method, &Handlers::Core.method(:cancel_request_notification))
      end
    end

    def validate_prompt_arguments(argument_defs)
      raise ArgumentError, "arguments must be an Array" unless argument_defs.is_a?(Array)

      argument_defs.each_with_index do |arg, idx|
        raise ArgumentError, "argument definition at index #{idx} must be a Hash" unless arg.is_a?(Hash)

        # Required field :name
        name_val = arg[:name] || arg["name"]
        raise ArgumentError, "argument definition at index #{idx} missing :name" if name_val.nil?

        raise ArgumentError, "argument :name at index #{idx} must be String or Symbol" unless name_val.is_a?(String) || name_val.is_a?(Symbol)

        # Optional :description
        if arg.key?(:description) || arg.key?("description")
          desc_val = arg[:description] || arg["description"]
          raise ArgumentError, "argument :description at index #{idx} must be a String" unless desc_val.nil? || desc_val.is_a?(String)
        end

        # Optional :required boolean
        if arg.key?(:required) || arg.key?("required")
          req_val = arg[:required] || arg["required"]
          raise ArgumentError, "argument :required at index #{idx} must be boolean" unless [true, false].include?(req_val)
        end

        # Disallow unknown keys
        allowed_keys = %w[name description required]
        unknown_keys = arg.keys.map(&:to_s) - allowed_keys
        raise ArgumentError, "argument definition at index #{idx} has unknown keys: #{unknown_keys.join(",")}" unless unknown_keys.empty?
      end
    end
  end
end
