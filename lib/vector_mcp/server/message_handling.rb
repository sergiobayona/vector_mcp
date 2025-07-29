# frozen_string_literal: true

module VectorMCP
  class Server
    # Handles message processing and request/notification dispatching
    module MessageHandling
      # --- Message Handling Logic (primarily called by transports) ---

      # Handles an incoming JSON-RPC message (request or notification).
      # This is the main dispatch point for messages received by a transport.
      #
      # @param message [Hash] The parsed JSON-RPC message object.
      # @param session [VectorMCP::Session] The client session associated with this message.
      # @param session_id [String] A unique identifier for the underlying transport connection.
      # @return [Object, nil] For requests, returns the result data to be sent in the JSON-RPC response.
      #   For notifications, returns `nil`.
      # @raise [VectorMCP::ProtocolError] if the message is invalid or an error occurs during handling.
      def handle_message(message, session, session_id)
        id = message["id"]
        method = message["method"]
        params = message["params"] || {}

        if id && method # Request
          logger.debug("[#{session_id}] Request [#{id}]: #{method} with params: #{params.inspect}")
          handle_request(id, method, params, session)
        elsif method # Notification
          logger.debug("[#{session_id}] Notification: #{method} with params: #{params.inspect}")
          handle_notification(method, params, session)
          nil # Notifications do not have a return value to send back to client
        elsif id # Invalid: Has ID but no method
          logger.warn("[#{session_id}] Invalid message: Has ID [#{id}] but no method. #{message.inspect}")
          raise VectorMCP::InvalidRequestError.new("Request object must include a 'method' member.", request_id: id)
        else # Invalid: No ID and no method
          logger.warn("[#{session_id}] Invalid message: Missing both 'id' and 'method'. #{message.inspect}")
          raise VectorMCP::InvalidRequestError.new("Invalid message format", request_id: nil)
        end
      end

      # --- Request/Notification Hook Methods ---

      # Registers a handler for a specific JSON-RPC request method.
      #
      # @param method [String, Symbol] The method name (e.g., "my/customMethod").
      # @yield [params, session, server] A block to handle the request.
      # @return [self] The server instance.
      def on_request(method, &handler)
        @request_handlers[method.to_s] = handler
        self
      end

      # Registers a handler for a specific JSON-RPC notification method.
      #
      # @param method [String, Symbol] The method name (e.g., "my/customNotification").
      # @yield [params, session, server] A block to handle the notification.
      # @return [self] The server instance.
      def on_notification(method, &handler)
        @notification_handlers[method.to_s] = handler
        self
      end

      private

      # Internal handler for JSON-RPC requests.
      # @api private
      def handle_request(id, method, params, session)
        validate_session_initialization(id, method, params, session)

        handler = @request_handlers[method]
        raise VectorMCP::MethodNotFoundError.new(method, request_id: id) unless handler

        execute_request_handler(id, method, params, session, handler)
      end

      # Validates that the session is properly initialized for the given request.
      # @api private
      def validate_session_initialization(id, method, _params, session)
        # Handle both direct VectorMCP::Session and BaseSessionManager::Session wrapper
        actual_session = session.respond_to?(:context) ? session.context : session
        return if actual_session.initialized?

        # Allow "initialize" even if not marked initialized yet by server
        return if method == "initialize"

        # For any other method, session must be initialized
        raise VectorMCP::InitializationError.new("Session not initialized. Client must send 'initialize' first.", request_id: id)
      end

      # Executes the request handler with proper error handling and tracking.
      # @api private
      def execute_request_handler(id, method, params, session, handler)
        @in_flight_requests[id] = { method: method, params: params, session: session, start_time: Time.now }
        result = handler.call(params, session, self)
        result
      rescue VectorMCP::ProtocolError => e
        # Ensure the request ID from the current context is on the error
        e.request_id = id unless e.request_id && e.request_id == id
        raise e # Re-raise with potentially updated request_id
      rescue StandardError => e
        handle_request_error(id, method, e)
      ensure
        @in_flight_requests.delete(id)
      end

      # Handles unexpected errors during request processing.
      # @api private
      def handle_request_error(id, method, error)
        logger.error("Unhandled error during request '#{method}' (ID: #{id}): #{error.message}\nBacktrace: #{error.backtrace.join("\n  ")}")
        raise VectorMCP::InternalError.new(
          "Request handler failed unexpectedly",
          request_id: id,
          details: { method: method, error: "An internal error occurred" }
        )
      end

      # Internal handler for JSON-RPC notifications.
      # @api private
      def handle_notification(method, params, session)
        # Handle both direct VectorMCP::Session and BaseSessionManager::Session wrapper
        actual_session = session.respond_to?(:context) ? session.context : session
        unless actual_session.initialized? || method == "initialized"
          logger.warn("Ignoring notification '#{method}' before session is initialized. Params: #{params.inspect}")
          return
        end

        handler = @notification_handlers[method]
        if handler
          begin
            handler.call(params, session, self)
          rescue StandardError => e
            logger.error("Error executing notification handler '#{method}': #{e.message}\nBacktrace (top 5):\n  #{e.backtrace.first(5).join("\n  ")}")
            # Notifications must not generate a response, even on error.
          end
        else
          logger.debug("No handler registered for notification: #{method}")
        end
      end

      # Sets up default handlers for core MCP methods using {VectorMCP::Handlers::Core}.
      # @api private
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
        on_request("roots/list", &Handlers::Core.method(:list_roots))

        # Core Notifications
        on_notification("initialized", &Handlers::Core.method(:initialized_notification))
        # Standard cancel request names
        %w[$/cancelRequest $/cancel notifications/cancelled].each do |cancel_method|
          on_notification(cancel_method, &Handlers::Core.method(:cancel_request_notification))
        end
      end

      # Helper to create a proc that calls a method on the session object.
      # @api private
      def session_method(method_name)
        lambda do |params, session, _server|
          # Handle both direct VectorMCP::Session and BaseSessionManager::Session wrapper
          actual_session = session.respond_to?(:context) ? session.context : session
          actual_session.public_send(method_name, params)
        end
      end
    end
  end
end
