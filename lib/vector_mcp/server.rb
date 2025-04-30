# frozen_string_literal: true

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

      @prompts[name_s] = Prompt.new(name_s, description, arguments, handler)
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
        transport_instance.run
      when :sse
        # Pass options like host, port, path_prefix to the SSE transport
        transport_instance = VectorMCP::Transport::SSE.new(self, options)
        transport_instance.run
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
      caps[:prompts] = { listChanged: false } unless @prompts.empty?
      caps[:experimental] = {}
      caps
    end

    private

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
      rescue VectorMCP::NotFoundError, VectorMCP::InvalidParamsError, VectorMCP::InternalError
        raise # Re-raise known protocol errors (including those from handlers)
      rescue StandardError => e
        # Log the detailed error for server-side debugging
        logger.error("Unhandled error during request '#{method}': #{e.message}\n#{e.backtrace.join("\n")}")
        # Wrap unexpected errors in InternalError, but limit client-facing details
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

      # Core Notifications
      on_notification("initialized", &Handlers::Core.method(:initialized_notification))
      # Handle multiple potential names for cancellation
      %w[$/cancelRequest $/cancel notifications/cancelled].each do |cancel_method|
        on_notification(cancel_method, &Handlers::Core.method(:cancel_request_notification))
      end
    end
  end
end
