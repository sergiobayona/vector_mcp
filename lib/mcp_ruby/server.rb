# frozen_string_literal: true

require "logger"
require_relative "definitions"
require_relative "session"
require_relative "errors"
require_relative "transport/stdio" # Default transport
require_relative "handlers/core" # Default handlers
require_relative "util" # Needed if not using Handlers::Core

module MCPRuby
  # Central class for the MCP Server implementation.
  class Server
    include Definitions # Make Tool, Resource, Prompt structs easily available

    PROTOCOL_VERSION = "2024-11-05"

    attr_reader :logger, :name, :version, :protocol_version, :tools, :resources, :prompts, :in_flight_requests

    def initialize(name:, version: "0.1.0", log_level: Logger::INFO, protocol_version: PROTOCOL_VERSION)
      @name = name
      @version = version
      @protocol_version = protocol_version
      @logger = MCPRuby.logger # Use the shared logger instance
      @logger.level = log_level

      @request_handlers = {}
      @notification_handlers = {}
      @tools = {}
      @resources = {}
      @prompts = {}
      @in_flight_requests = {} # Track requests for cancellation

      setup_default_handlers
      logger.info("Server instance '#{name}' v#{version} (using MCPRuby v#{MCPRuby::VERSION}) initialized.")
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

    def run(transport: :stdio)
      case transport
      when :stdio
        transport_instance = MCPRuby::Transport::Stdio.new(self)
        transport_instance.run
      # Add other transports later
      # when :sse
      #   MCPRuby::Transport::SSE.new(self).run
      else
        logger.fatal("Unsupported transport: #{transport}")
        raise ArgumentError, "Unsupported transport: #{transport}"
      end
    end

    # --- Message Handling Logic (called by transport) ---

    def handle_message(message, session, transport)
      id = message["id"]
      method = message["method"]
      params = message["params"] || {} # Ensure params is always a hash

      if id && method # It's a request
        logger.info("Received request [#{id}]: #{method}")
        handle_request(id, method, params, session, transport)
      elsif method # It's a notification
        logger.info("Received notification: #{method}")
        handle_notification(method, params, session, transport)
      elsif id # It's a response (client shouldn't send these)
        logger.warn("Received unexpected response [#{id}]")
      else # Invalid message
        # Raise error to be caught by transport's handler_line
        raise MCPRuby::InvalidRequestError, "Invalid message format: #{message.inspect}"
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

    def handle_request(id, method, params, session, transport)
      unless session.initialized?
        raise MCPRuby::InitializationError.new(request_id: id) unless method == "initialize"

        result = session.initialize!(params)
        transport.send_response(id, result)

        # Raise specific error

        return
      end

      handler = @request_handlers[method]
      raise MCPRuby::MethodNotFoundError.new(method, request_id: id) unless handler

      begin
        @in_flight_requests[id] = { method: method, params: params, session: session, transport: transport }
        # Pass params, session, and server instance to the handler
        result = handler.call(params, session, self)
        transport.send_response(id, result)
      # Catch application-level errors defined in handlers/core or user code
      rescue MCPRuby::NotFoundError, MCPRuby::InvalidParamsError
        raise # Re-raise known protocol errors to be handled by transport
      rescue StandardError => e
        logger.error("Error executing request '#{method}': #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        # Wrap unexpected errors in InternalError
        raise MCPRuby::InternalError.new("Request handler failed", request_id: id,
                                                                   details: { method: method, error: e.message, backtrace: e.backtrace.first(5) })
      ensure
        @in_flight_requests.delete(id)
      end
    end

    def handle_notification(method, params, session, _transport)
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
