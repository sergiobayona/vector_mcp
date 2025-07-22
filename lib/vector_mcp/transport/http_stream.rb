# frozen_string_literal: true

require "json"
require "securerandom"
require "puma"
require "rack"
require "concurrent-ruby"
require "timeout"

require_relative "../errors"
require_relative "../util"
require_relative "../session"
require_relative "http_stream/session_manager"
require_relative "http_stream/event_store"
require_relative "http_stream/stream_handler"

module VectorMCP
  module Transport
    # Implements the Model Context Protocol transport over HTTP with streaming support
    # according to the MCP specification for Streamable HTTP transport.
    #
    # This transport supports:
    # - Client-to-server communication via HTTP POST
    # - Optional server-to-client streaming via Server-Sent Events (SSE)
    # - Session management with Mcp-Session-Id headers
    # - Resumable connections with event IDs and Last-Event-ID support
    # - Bidirectional communication patterns
    #
    # Endpoints:
    # - POST /mcp - Client sends JSON-RPC requests
    # - GET /mcp - Optional SSE streaming for server-initiated messages
    # - DELETE /mcp - Session termination
    #
    # @example Basic Usage
    #   server = VectorMCP::Server.new("http-stream-server")
    #   transport = VectorMCP::Transport::HttpStream.new(server, port: 8080)
    #   server.run(transport: transport)
    #
    # @attr_reader logger [Logger] The logger instance, shared with the server
    # @attr_reader server [VectorMCP::Server] The server instance this transport is bound to
    # @attr_reader host [String] The hostname or IP address the server will bind to
    # @attr_reader port [Integer] The port number the server will listen on
    # @attr_reader path_prefix [String] The base URL path for MCP endpoints
    # rubocop:disable Metrics/ClassLength
    class HttpStream
      attr_reader :logger, :server, :host, :port, :path_prefix

      # Default configuration values
      DEFAULT_HOST = "localhost"
      DEFAULT_PORT = 8000
      DEFAULT_PATH_PREFIX = "/mcp"
      DEFAULT_SESSION_TIMEOUT = 300 # 5 minutes
      DEFAULT_EVENT_RETENTION = 100 # Keep last 100 events for resumability
      DEFAULT_REQUEST_TIMEOUT = 30 # Default timeout for server-initiated requests

      # Initializes a new HTTP Stream transport.
      #
      # @param server [VectorMCP::Server] The server instance that will handle messages
      # @param options [Hash] Configuration options for the transport
      # @option options [String] :host ("localhost") The hostname or IP to bind to
      # @option options [Integer] :port (8000) The port to listen on
      # @option options [String] :path_prefix ("/mcp") The base path for HTTP endpoints
      # @option options [Integer] :session_timeout (300) Session timeout in seconds
      # @option options [Integer] :event_retention (100) Number of events to retain for resumability
      # @option options [Array<String>] :allowed_origins (["*"]) List of allowed origins for CORS. Use ["*"] to allow all origins.
      def initialize(server, options = {})
        @server = server
        @logger = server.logger
        initialize_configuration(options)
        initialize_components
        initialize_request_tracking
        initialize_object_pools
        initialize_server_state

        logger.debug { "HttpStream transport initialized: #{@host}:#{@port}#{@path_prefix}" }
      end

      # Starts the HTTP Stream transport.
      # This method will block until the server is stopped.
      #
      # @return [void]
      # @raise [StandardError] if there's a fatal error during server startup
      def run
        start_puma_server
      rescue StandardError => e
        handle_fatal_error(e)
      end

      # Handles incoming HTTP requests (Rack interface).
      # Routes requests to appropriate handlers based on path and method.
      #
      # @param env [Hash] The Rack environment hash
      # @return [Array(Integer, Hash, Object)] Standard Rack response triplet
      def call(env)
        start_time = Time.now
        path = env["PATH_INFO"]
        method = env["REQUEST_METHOD"]

        # Processing HTTP request

        response = route_request(path, method, env)
        log_request_completion(method, path, start_time, response[0])
        response
      rescue StandardError => e
        handle_request_error(method, path, e)
      end

      # Sends a notification to the first available session.
      #
      # @param method [String] The notification method name
      # @param params [Hash, Array, nil] The notification parameters
      # @return [Boolean] True if notification was sent successfully
      def send_notification(method, params = nil)
        # Find the first available session
        first_session = find_first_session
        return false unless first_session

        message = build_notification(method, params)
        @stream_handler.send_message_to_session(first_session, message)
      end

      # Sends a notification to a specific session.
      #
      # @param session_id [String] The target session ID
      # @param method [String] The notification method name
      # @param params [Hash, Array, nil] The notification parameters
      # @return [Boolean] True if notification was sent successfully
      def send_notification_to_session(session_id, method, params = nil)
        session = @session_manager.get_session(session_id)
        return false unless session

        message = build_notification(method, params)
        @stream_handler.send_message_to_session(session, message)
      end

      # Broadcasts a notification to all active sessions.
      #
      # @param method [String] The notification method name
      # @param params [Hash, Array, nil] The notification parameters
      # @return [Integer] Number of sessions the notification was sent to
      def broadcast_notification(method, params = nil)
        message = build_notification(method, params)
        @session_manager.broadcast_message(message)
      end

      # Sends a server-initiated JSON-RPC request compatible with Session expectations.
      # This method will block until a response is received or the timeout is reached.
      # For HTTP transport, this requires finding an appropriate session with streaming connection.
      #
      # @param method [String] The request method name
      # @param params [Hash, Array, nil] The request parameters
      # @param timeout [Numeric] How long to wait for a response, in seconds
      # @return [Object] The result part of the client's response
      # @raise [VectorMCP::SamplingError, VectorMCP::SamplingTimeoutError] if the client returns an error or times out
      # @raise [ArgumentError] if method is blank or no streaming session found
      def send_request(method, params = nil, timeout: DEFAULT_REQUEST_TIMEOUT)
        raise ArgumentError, "Method cannot be blank" if method.to_s.strip.empty?

        # Find the first session with streaming connection
        # In HTTP transport, we need an active streaming connection to send server-initiated requests
        streaming_session = find_streaming_session
        raise ArgumentError, "No streaming session available for server-initiated requests" unless streaming_session

        send_request_to_session(streaming_session.id, method, params, timeout: timeout)
      end

      # Sends a server-initiated JSON-RPC request to a specific session and waits for a response.
      # This method will block until a response is received or the timeout is reached.
      #
      # @param session_id [String] The target session ID
      # @param method [String] The request method name
      # @param params [Hash, Array, nil] The request parameters
      # @param timeout [Numeric] How long to wait for a response, in seconds
      # @return [Object] The result part of the client's response
      # @raise [VectorMCP::SamplingError, VectorMCP::SamplingTimeoutError] if the client returns an error or times out
      # @raise [ArgumentError] if method is blank or session not found
      def send_request_to_session(session_id, method, params = nil, timeout: DEFAULT_REQUEST_TIMEOUT)
        raise ArgumentError, "Method cannot be blank" if method.to_s.strip.empty?
        raise ArgumentError, "Session ID cannot be blank" if session_id.to_s.strip.empty?

        session = @session_manager.get_session(session_id)
        raise ArgumentError, "Session not found: #{session_id}" unless session

        raise ArgumentError, "Session must have streaming connection for server-initiated requests" unless session.streaming?

        request_id = generate_request_id
        request_payload = { jsonrpc: "2.0", id: request_id, method: method }
        request_payload[:params] = params if params

        setup_request_tracking(request_id)
        # Sending request to session

        # Send request via existing streaming connection
        unless @stream_handler.send_message_to_session(session, request_payload)
          cleanup_request_tracking(request_id)
          raise VectorMCP::SamplingError, "Failed to send request to session #{session_id}"
        end

        response = wait_for_response(request_id, method, timeout)
        process_response(response, request_id, method)
      end

      # Stops the transport and cleans up resources.
      #
      # @return [void]
      def stop
        logger.info { "Stopping HttpStream transport" }
        @running = false
        cleanup_all_pending_requests
        @session_manager.cleanup_all_sessions
        @puma_server&.stop
        logger.info { "HttpStream transport stopped" }
      end

      # Provides access to session manager for internal components.
      #
      # @return [HttpStream::SessionManager]
      # @api private
      attr_reader :session_manager

      # Provides access to event store for internal components.
      #
      # @return [HttpStream::EventStore]
      # @api private
      attr_reader :event_store

      # Provides access to stream handler for internal components.
      #
      # @return [HttpStream::StreamHandler]
      # @api private
      attr_reader :stream_handler

      private

      # Normalizes the path prefix to ensure it starts with / and doesn't end with /
      #
      # @param prefix [String] The path prefix to normalize
      # @return [String] The normalized path prefix
      def normalize_path_prefix(prefix)
        prefix = prefix.to_s
        prefix = "/#{prefix}" unless prefix.start_with?("/")
        prefix = prefix.chomp("/")
        prefix.empty? ? "/" : prefix
      end

      # Starts the Puma HTTP server
      #
      # @return [void]
      def start_puma_server
        @puma_server = Puma::Server.new(self)
        @puma_server.add_tcp_listener(@host, @port)

        @running = true
        setup_signal_handlers

        logger.info { "HttpStream server listening on #{@host}:#{@port}#{@path_prefix}" }
        @puma_server.run.join
      rescue StandardError => e
        logger.error { "Error starting Puma server: #{e.message}" }
        raise
      ensure
        cleanup_server
      end

      # Sets up signal handlers for graceful shutdown
      #
      # @return [void]
      def setup_signal_handlers
        %w[INT TERM].each do |signal|
          Signal.trap(signal) do
            # Use a simple flag to avoid trap context issues
            @running = false
            # Defer the actual shutdown to avoid trap context limitations
            Thread.new { stop_server_safely }
          end
        end
      end

      # Safely stops the server outside of trap context
      #
      # @return [void]
      def stop_server_safely
        return unless @puma_server

        begin
          @puma_server.stop
        rescue StandardError => e
          # Simple puts to avoid logger issues in signal context
          puts "Error stopping server: #{e.message}"
        end
      end

      # Cleans up server resources
      #
      # @return [void]
      def cleanup_server
        cleanup_all_pending_requests
        @session_manager.cleanup_all_sessions
        @running = false
        logger.info { "HttpStream server cleanup completed" }
      end

      # Routes requests to appropriate handlers
      #
      # @param path [String] The request path
      # @param method [String] The HTTP method
      # @param env [Hash] The Rack environment
      # @return [Array] Rack response triplet
      def route_request(path, method, env)
        return handle_health_check if path == "/"
        return not_found_response unless path == @path_prefix

        # Validate origin for security (MCP specification requirement)
        return forbidden_response("Origin not allowed") unless valid_origin?(env)

        case method
        when "POST"
          handle_post_request(env)
        when "GET"
          handle_get_request(env)
        when "DELETE"
          handle_delete_request(env)
        else
          method_not_allowed_response(%w[POST GET DELETE])
        end
      end

      # Handles POST requests (client-to-server JSON-RPC)
      #
      # @param env [Hash] The Rack environment
      # @return [Array] Rack response triplet
      def handle_post_request(env)
        session_id = extract_session_id(env)
        session = @session_manager.get_or_create_session(session_id, env)

        request_body = read_request_body(env)
        message = parse_json_message(request_body)

        # Check if this is a response to a server-initiated request
        if outgoing_response?(message)
          handle_outgoing_response(message)
          # For responses, return 202 Accepted with no body
          return [202, { "Mcp-Session-Id" => session.id }, []]
        end

        result = @server.handle_message(message, session.context, session.id)

        # Set session ID header in response
        headers = { "Mcp-Session-Id" => session.id }
        json_rpc_response(result, message["id"], headers)
      rescue VectorMCP::ProtocolError => e
        json_error_response(e.request_id, e.code, e.message, e.details)
      rescue JSON::ParserError => e
        json_error_response(nil, -32_700, "Parse error", { details: e.message })
      end

      # Handles GET requests (SSE streaming)
      #
      # @param env [Hash] The Rack environment
      # @return [Array] Rack response triplet
      def handle_get_request(env)
        session_id = extract_session_id(env)
        return bad_request_response("Missing Mcp-Session-Id header") unless session_id

        session = @session_manager.get_or_create_session(session_id, env)
        return not_found_response unless session

        @stream_handler.handle_streaming_request(env, session)
      end

      # Handles DELETE requests (session termination)
      #
      # @param env [Hash] The Rack environment
      # @return [Array] Rack response triplet
      def handle_delete_request(env)
        session_id = extract_session_id(env)
        return bad_request_response("Missing Mcp-Session-Id header") unless session_id

        success = @session_manager.session_terminated?(session_id)
        if success
          [204, {}, []]
        else
          not_found_response
        end
      end

      # Extracts session ID from request headers
      #
      # @param env [Hash] The Rack environment
      # @return [String, nil] The session ID or nil if not present
      def extract_session_id(env)
        env["HTTP_MCP_SESSION_ID"]
      end

      # Reads and returns the request body
      #
      # @param env [Hash] The Rack environment
      # @return [String] The request body
      def read_request_body(env)
        input = env["rack.input"]
        input.rewind
        input.read
      end

      # Optimized JSON parsing with better error handling and performance
      #
      # @param body [String] The request body
      # @return [Hash] The parsed JSON message
      # @raise [JSON::ParserError] if JSON is invalid
      def parse_json_message(body)
        # Early validation to avoid expensive parsing on malformed input
        return {} if body.nil? || body.empty?

        # Fast-path check for basic JSON structure
        body_stripped = body.strip
        return {} unless (body_stripped.start_with?("{") && body_stripped.end_with?("}")) ||
                         (body_stripped.start_with?("[") && body_stripped.end_with?("]"))

        JSON.parse(body_stripped)
      rescue JSON::ParserError => e
        logger.warn { "JSON parsing failed: #{e.message}" }
        raise
      end

      # Builds a notification message
      #
      # @param method [String] The notification method
      # @param params [Hash, Array, nil] The notification parameters
      # @return [Hash] The notification message
      def build_notification(method, params = nil)
        message = { jsonrpc: "2.0", method: method }
        message[:params] = params if params
        message
      end

      # Response helper methods
      def handle_health_check
        [200, { "Content-Type" => "text/plain" }, ["VectorMCP HttpStream Server OK"]]
      end

      def json_response(data, headers = {})
        response_headers = { "Content-Type" => "application/json" }.merge(headers)
        [200, response_headers, [data.to_json]]
      end

      def json_rpc_response(result, request_id, headers = {})
        # Use pooled hash for response to reduce allocation
        response = @hash_pool.pop || {}
        response.clear
        response[:jsonrpc] = "2.0"
        response[:id] = request_id
        response[:result] = result

        response_headers = { "Content-Type" => "application/json" }.merge(headers)
        json_result = response.to_json

        # Return hash to pool after JSON conversion
        @hash_pool << response if @hash_pool.size < 20

        [200, response_headers, [json_result]]
      end

      def json_error_response(id, code, message, data = nil)
        error_obj = { code: code, message: message }
        error_obj[:data] = data if data
        response = { jsonrpc: "2.0", id: id, error: error_obj }
        [400, { "Content-Type" => "application/json" }, [response.to_json]]
      end

      def not_found_response
        [404, { "Content-Type" => "text/plain" }, ["Not Found"]]
      end

      def bad_request_response(message = "Bad Request")
        [400, { "Content-Type" => "text/plain" }, [message]]
      end

      def forbidden_response(message = "Forbidden")
        [403, { "Content-Type" => "text/plain" }, [message]]
      end

      def method_not_allowed_response(allowed_methods)
        [405, { "Content-Type" => "text/plain", "Allow" => allowed_methods.join(", ") },
         ["Method Not Allowed"]]
      end

      # Validates the Origin header for security
      #
      # @param env [Hash] The Rack environment
      # @return [Boolean] True if origin is allowed, false otherwise
      def valid_origin?(env)
        return true if @allowed_origins.include?("*")

        origin = env["HTTP_ORIGIN"]
        return true if origin.nil? # Allow requests without Origin header (e.g., server-to-server)

        @allowed_origins.include?(origin)
      end

      # Logging and error handling
      def log_request_completion(method, path, start_time, status)
        duration = Time.now - start_time
        logger.debug { "#{method} #{path} #{status} (#{(duration * 1000).round(2)}ms)" }
      end

      def handle_request_error(method, path, error)
        logger.error { "Request processing error for #{method} #{path}: #{error.message}" }
        [500, { "Content-Type" => "text/plain" }, ["Internal Server Error"]]
      end

      def handle_fatal_error(error)
        logger.fatal { "Fatal error in HttpStream transport: #{error.message}" }
        exit(1)
      end

      # Request tracking helpers for server-initiated requests

      # Sets up tracking for an outgoing request using pooled condition variables.
      #
      # @param request_id [String] The request ID to track
      # @return [void]
      def setup_request_tracking(request_id)
        @request_mutex.synchronize do
          # Create IVar for thread-safe request tracking (no race conditions)
          @outgoing_request_ivars[request_id] = Concurrent::IVar.new
        end
      end

      # Waits for a response to an outgoing request.
      #
      # @param request_id [String] The request ID to wait for
      # @param method [String] The request method name
      # @param timeout [Numeric] How long to wait
      # @return [Hash] The response data
      # @raise [VectorMCP::SamplingTimeoutError] if timeout occurs
      def wait_for_response(request_id, method, timeout)
        ivar = nil
        @request_mutex.synchronize do
          ivar = @outgoing_request_ivars[request_id]
        end

        return nil unless ivar

        begin
          # IVar handles timeout and thread safety automatically
          response = ivar.value!(timeout)
          logger.debug { "Received response for request ID #{request_id}" }
          response
        rescue Concurrent::TimeoutError
          logger.warn { "Timeout waiting for response to request ID #{request_id} (#{method}) after #{timeout}s" }
          cleanup_request_tracking(request_id)
          raise VectorMCP::SamplingTimeoutError, "Timeout waiting for client response to '#{method}' request (ID: #{request_id})"
        end
      end

      # Processes the response from an outgoing request.
      #
      # @param response [Hash, nil] The response data
      # @param request_id [String] The request ID
      # @param method [String] The request method name
      # @return [Object] The result data
      # @raise [VectorMCP::SamplingError] if response contains an error or is nil
      def process_response(response, request_id, method)
        if response.nil?
          raise VectorMCP::SamplingError, "No response received for '#{method}' request (ID: #{request_id}) - this indicates a logic error."
        end

        if response.key?(:error)
          err = response[:error]
          logger.warn { "Client returned error for request ID #{request_id} (#{method}): #{err.inspect}" }
          raise VectorMCP::SamplingError, "Client returned an error for '#{method}' request (ID: #{request_id}): [#{err[:code]}] #{err[:message]}"
        end

        # Check if response has result key, if not treat as malformed
        unless response.key?(:result)
          raise VectorMCP::SamplingError, "Malformed response for '#{method}' request (ID: #{request_id}): missing 'result' field. Response: #{response.inspect}"
        end

        response[:result]
      end

      # Cleans up tracking for a request and returns condition variable to pool.
      #
      # @param request_id [String] The request ID to clean up
      # @return [void]
      def cleanup_request_tracking(request_id)
        @request_mutex.synchronize do
          cleanup_request_tracking_unsafe(request_id)
        end
      end

      # Internal cleanup method that assumes mutex is already held.
      # This prevents recursive locking when called from within synchronized blocks.
      #
      # @param request_id [String] The request ID to clean up
      # @return [void]
      # @api private
      def cleanup_request_tracking_unsafe(request_id)
        # Remove IVar for this request (no condition variable cleanup needed)
        @outgoing_request_ivars.delete(request_id)
      end

      # Checks if a message is a response to an outgoing request.
      #
      # @param message [Hash] The parsed message
      # @return [Boolean] True if this is an outgoing response
      def outgoing_response?(message)
        return false unless message["id"]
        return false if message["method"]

        # Standard response with result or error
        return true if message.key?("result") || message.key?("error")

        # Handle malformed responses: if we have a pending request with this ID,
        # treat it as a response (even if malformed) rather than letting it
        # go through normal request processing
        request_id = message["id"]
        @outgoing_request_ivars.key?(request_id)
      end

      # Handles a response to an outgoing request.
      #
      # @param message [Hash] The parsed response message
      # @return [void]
      def handle_outgoing_response(message)
        request_id = message["id"]
        
        ivar = nil
        @request_mutex.synchronize do
          ivar = @outgoing_request_ivars[request_id]
        end

        unless ivar
          logger.debug { "Received response for request ID #{request_id} but no thread is waiting (likely timed out)" }
          return
        end

        # Convert keys to symbols for consistency and put response in IVar
        response_data = deep_transform_keys(message, &:to_sym)
        
        # IVar handles thread-safe response delivery - no race conditions possible
        if ivar.try_set(response_data)
          logger.debug { "Response delivered to waiting thread for request ID #{request_id}" }
        else
          logger.debug { "IVar was already resolved for request ID #{request_id} (duplicate response)" }
        end
      end

      # Optimized hash key transformation for better performance.
      # Uses simple recursive approach but with early returns to reduce overhead.
      #
      # @param obj [Object] The object to transform (Hash, Array, or other)
      # @return [Object] The transformed object
      def deep_transform_keys(obj, &block)
        transform_object_keys(obj, &block)
      end

      # Core transformation logic extracted for better maintainability
      def transform_object_keys(obj, &block)
        case obj
        when Hash
          # Pre-allocate hash with known size for efficiency
          result = Hash.new(obj.size)
          obj.each do |k, v|
            # Safe key transformation - only transform string keys to symbols
            new_key = if block && (k.is_a?(String) || k.is_a?(Symbol))
                        block.call(k)
                      else
                        k
                      end
            result[new_key] = transform_object_keys(v, &block)
          end
          result
        when Array
          # Use map! for in-place transformation when possible
          obj.map { |v| transform_object_keys(v, &block) }
        else
          obj
        end
      end

      # Initialize configuration options from the provided options hash
      def initialize_configuration(options)
        @host = options[:host] || DEFAULT_HOST
        @port = options[:port] || DEFAULT_PORT
        @path_prefix = normalize_path_prefix(options[:path_prefix] || DEFAULT_PATH_PREFIX)
        @session_timeout = options[:session_timeout] || DEFAULT_SESSION_TIMEOUT
        @event_retention = options[:event_retention] || DEFAULT_EVENT_RETENTION
        @allowed_origins = options[:allowed_origins] || ["*"]
      end

      # Initialize core HTTP stream components
      def initialize_components
        @session_manager = HttpStream::SessionManager.new(self, @session_timeout)
        @event_store = HttpStream::EventStore.new(@event_retention)
        @stream_handler = HttpStream::StreamHandler.new(self)
      end

      # Initialize request tracking system and ID generation for server-initiated requests
      def initialize_request_tracking
        # Use IVars for thread-safe request/response handling (eliminates condition variable races)
        @outgoing_request_ivars = Concurrent::Hash.new
        @request_mutex = Mutex.new
        initialize_request_id_generation
      end

      # Initialize thread-safe request ID generation components
      def initialize_request_id_generation
        # Thread-safe request ID generation - avoid Fiber/Enumerator which can't cross threads
        @request_id_base = "vecmcp_http_#{Process.pid}_#{SecureRandom.hex(4)}"
        @request_id_counter = Concurrent::AtomicFixnum.new(0)
      end

      # Generate a unique, thread-safe request ID for server-initiated requests
      #
      # @return [String] A unique request ID in format: vecmcp_http_{pid}_{random}_{counter}
      def generate_request_id
        "#{@request_id_base}_#{@request_id_counter.increment}"
      end

      # Initialize object pools for performance optimization
      def initialize_object_pools
        # Pool for reusable hash objects to reduce GC pressure
        @hash_pool = Concurrent::Array.new
        20.times { @hash_pool << {} }
      end

      # Initialize server state variables
      def initialize_server_state
        @puma_server = nil
        @running = false
      end

      # Cleans up all pending requests during shutdown.
      #
      # @return [void]
      def cleanup_all_pending_requests
        return if @outgoing_request_ivars.empty?

        logger.debug { "Cleaning up #{@outgoing_request_ivars.size} pending requests" }

        @request_mutex.synchronize do
          # IVars will timeout naturally, just clear the tracking
          @outgoing_request_ivars.clear
        end
      end

      # Finds the first session with an active streaming connection.
      #
      # @return [SessionManager::Session, nil] The first streaming session or nil if none found
      def find_streaming_session
        @session_manager.active_session_ids.each do |session_id|
          session = @session_manager.get_session(session_id)
          return session if session&.streaming?
        end
        nil
      end

      # Finds the first available session (streaming or non-streaming).
      #
      # @return [SessionManager::Session, nil] The first available session or nil if none found
      def find_first_session
        session_ids = @session_manager.active_session_ids
        return nil if session_ids.empty?

        @session_manager.get_session(session_ids.first)
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
