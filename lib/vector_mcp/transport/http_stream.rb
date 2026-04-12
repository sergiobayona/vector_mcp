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

      # Default allowed origins — restrict to localhost by default for security.
      DEFAULT_ALLOWED_ORIGINS = %w[
        http://localhost
        https://localhost
        http://127.0.0.1
        https://127.0.0.1
        http://[::1]
        https://[::1]
      ].freeze

      # Initializes a new HTTP Stream transport.
      #
      # @param server [VectorMCP::Server] The server instance that will handle messages
      # @param options [Hash] Configuration options for the transport
      # @option options [String] :host ("localhost") The hostname or IP to bind to
      # @option options [Integer] :port (8000) The port to listen on
      # @option options [String] :path_prefix ("/mcp") The base path for HTTP endpoints
      # @option options [Integer] :session_timeout (300) Session timeout in seconds
      # @option options [Integer] :event_retention (100) Number of events to retain for resumability
      # @option options [Array<String>] :allowed_origins Allowed origins for CORS validation.
      #   Defaults to localhost origins only. Pass ["*"] to allow all origins (NOT recommended for production).
      def initialize(server, options = {})
        @server = server
        @logger = server.logger
        initialize_configuration(options)
        initialize_components
        initialize_request_tracking
        initialize_object_pools
        initialize_server_state

        logger.info { "HttpStream transport initialized: #{@host}:#{@port}#{@path_prefix}" }
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
        transport_context = build_transport_context(env, method, path, start_time)

        logger.debug { "Processing HTTP request #{method} #{path}" }

        transport_context = execute_transport_hooks(:before_request, transport_context)
        raise transport_context.error if transport_context.error?
        return transport_context.result if transport_context.result

        response = route_request(path, method, env)
        transport_context.result = response
        transport_context = execute_transport_hooks(:after_response, transport_context)
        raise transport_context.error if transport_context.error?

        response = transport_context.result || response
        log_request_completion(method, path, start_time, response[0])
        response
      rescue StandardError => e
        if transport_context
          transport_context.error = e
          transport_context = execute_transport_hooks(:on_transport_error, transport_context)
          return transport_context.result if transport_context.result
        end

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
        return route_mounted_request(path, method, env) if @mounted

        # Standalone mode: unchanged behavior
        return handle_health_check if path == "/"
        return not_found_response unless path == @path_prefix

        validate_and_dispatch(method, env)
      end

      # Routes requests when mounted inside another Rack app (e.g., Rails).
      # PATH_INFO is relative to the mount point: "/" = MCP endpoint, "/health" = health check.
      def route_mounted_request(path, method, env)
        return handle_health_check if path == "/health"
        return not_found_response unless ["", "/"].include?(path)

        validate_and_dispatch(method, env)
      end

      # Validates origin and dispatches to the appropriate handler by HTTP method.
      def validate_and_dispatch(method, env)
        return forbidden_response("Origin not allowed") unless valid_origin?(env)
        return unauthorized_oauth_response(env) if oauth_gate_should_reject?(env)

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

      # True when OAuth 2.1 resource server mode is enabled and the incoming
      # request has not successfully authenticated. Opt-in: only activates when the
      # server was configured with a +resource_metadata_url+ via +enable_authentication!+.
      #
      # @param env [Hash] The Rack environment
      # @return [Boolean]
      def oauth_gate_should_reject?(env)
        return false unless oauth_resource_server_enabled?

        !authenticate_transport_request(env).authenticated?
      end

      # @return [Boolean] true when the server is configured to act as an OAuth 2.1 resource server.
      def oauth_resource_server_enabled?
        return false unless @server.respond_to?(:oauth_resource_metadata_url)
        return false if @server.oauth_resource_metadata_url.nil?

        @server.auth_manager.required?
      end

      # Runs the configured authentication strategy against the Rack env and returns
      # the resulting SessionContext. The request is normalized into the
      # +{ headers:, params:, method:, path:, rack_env: }+ hash shape that the rest
      # of the codebase's authentication pipeline uses (see
      # +VectorMCP::Handlers::Core.extract_request_from_session+), so +:custom+
      # strategy handlers see the same contract here as they do on the in-handler
      # auth path. Errors in the strategy are logged and treated as unauthenticated
      # rather than propagated, so a malformed token can never crash the request
      # pipeline.
      #
      # @param env [Hash] The Rack environment
      # @return [VectorMCP::Security::SessionContext]
      def authenticate_transport_request(env)
        normalized_request = @server.security_middleware.normalize_request(env)
        @server.security_middleware.authenticate_request(normalized_request)
      rescue StandardError => e
        VectorMCP.logger_for("security").warn do
          "OAuth transport auth strategy raised #{e.class}: #{e.message}"
        end
        VectorMCP::Security::SessionContext.anonymous
      end

      # Returns a 401 Rack response carrying a WWW-Authenticate header that points
      # Claude Desktop (and other RFC 9728 clients) at the configured OAuth 2.1
      # protected resource metadata document. The JSON-RPC error envelope in the
      # body is for clients that parse bodies regardless of status code; the header
      # and status are the parts that drive the discovery flow.
      #
      # @param env [Hash] The Rack environment
      # @return [Array] Rack response triplet
      def unauthorized_oauth_response(env)
        VectorMCP.logger_for("security").info do
          "OAuth 401 challenge issued for #{env["REQUEST_METHOD"]} #{env["PATH_INFO"]}"
        end

        header_value = %(Bearer realm="mcp", resource_metadata="#{@server.oauth_resource_metadata_url}")
        body = {
          jsonrpc: "2.0",
          id: nil,
          error: { code: -32_401, message: "Authentication required" }
        }.to_json

        [401,
         { "Content-Type" => "application/json", "WWW-Authenticate" => header_value },
         [body]]
      end

      # Handles POST requests (client-to-server JSON-RPC)
      #
      # @param env [Hash] The Rack environment
      # @return [Array] Rack response triplet
      def handle_post_request(env)
        unless valid_post_accept?(env)
          logger.warn { "POST request with unsupported Accept header: #{env["HTTP_ACCEPT"]}" }
          return not_acceptable_response("Not Acceptable: POST requires Accept: application/json")
        end

        session_id = extract_session_id(env)
        request_body = read_request_body(env)
        parsed = parse_json_message(request_body)

        # MCP spec: POST body MUST be a single JSON-RPC message, not a batch array
        if parsed.is_a?(Array)
          return json_error_response(nil, -32_600, "Invalid Request",
                                     { details: "Batch requests are not supported. Send a single JSON-RPC message per POST." })
        end

        session = resolve_session_for_post(session_id, parsed, env)
        return session if session.is_a?(Array) # Rack error response

        # Validate MCP-Protocol-Version header (skip for initialize requests)
        is_initialize = parsed.is_a?(Hash) && parsed["method"] == "initialize"
        unless is_initialize
          version_error = validate_protocol_version_header(env)
          return version_error if version_error
        end

        handle_single_request(parsed, session, env)
      rescue JSON::ParserError => e
        json_error_response(nil, -32_700, "Parse error", { details: e.message })
      end

      # Handles a single JSON-RPC message from a POST request.
      #
      # @param message [Hash] Parsed JSON-RPC message
      # @param session [Session] The resolved session
      # @param env [Hash] The Rack environment
      # @return [Array] Rack response triplet
      def handle_single_request(message, session, env)
        if outgoing_response?(message)
          handle_outgoing_response(message)
          return [202, { "Mcp-Session-Id" => session.id }, []]
        end

        # Notifications: has method, no id -> 202 Accepted with no body (MCP spec requirement)
        if message["method"] && !message.key?("id")
          @server.handle_message(message, session.context, session.id)
          return [202, { "Mcp-Session-Id" => session.id }, []]
        end

        result = @server.handle_message(message, session.context, session.id)
        build_rpc_response(env, result, message["id"], session.id)
      rescue VectorMCP::ProtocolError => e
        build_protocol_error_response(env, e, session_id: session.id)
      end

      # Resolves or creates the session for a POST request following MCP spec rules:
      # - session_id present and known  → return existing session (updating request context)
      # - session_id present but unknown/expired → 404 Not Found
      # - no session_id + initialize request → create new session
      # - no session_id + other request → 400 Bad Request
      #
      # @param session_id [String, nil] Client-supplied Mcp-Session-Id header value
      # @param message [Hash] Parsed JSON-RPC message
      # @param env [Hash] Rack environment
      # @return [Session, Array] Session object or Rack error response triplet
      def resolve_session_for_post(session_id, message, env)
        is_initialize = message.is_a?(Hash) && message["method"] == "initialize"

        if session_id
          session = @session_manager.get_session(session_id)
          return not_found_response("Unknown or expired session") unless session

          if env
            request_context = VectorMCP::RequestContext.from_rack_env(env, "http_stream")
            session.context.request_context = request_context
          end
          session
        elsif is_initialize
          @session_manager.create_session(nil, env)
        else
          bad_request_response("Missing Mcp-Session-Id header")
        end
      end

      # Handles GET requests (SSE streaming)
      #
      # @param env [Hash] The Rack environment
      # @return [Array] Rack response triplet
      def handle_get_request(env)
        unless valid_get_accept?(env)
          logger.warn { "GET request with unsupported Accept header: #{env["HTTP_ACCEPT"]}" }
          return not_acceptable_response("Not Acceptable: GET requires Accept: text/event-stream")
        end

        session_id = extract_session_id(env)
        return bad_request_response("Missing Mcp-Session-Id header") unless session_id

        session = @session_manager.get_or_create_session(session_id, env)
        return not_found_response unless session

        version_error = validate_protocol_version_header(env)
        return version_error if version_error

        @stream_handler.handle_streaming_request(env, session)
      end

      # Handles DELETE requests (session termination)
      #
      # @param env [Hash] The Rack environment
      # @return [Array] Rack response triplet
      def handle_delete_request(env)
        session_id = extract_session_id(env)
        return bad_request_response("Missing Mcp-Session-Id header") unless session_id

        version_error = validate_protocol_version_header(env)
        return version_error if version_error

        success = @session_manager.terminate_session(session_id)
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
        raise JSON::ParserError, "Empty or nil body" if body.nil? || body.empty?

        # Fast-path check for basic JSON structure
        body_stripped = body.strip
        unless (body_stripped.start_with?("{") && body_stripped.end_with?("}")) ||
               (body_stripped.start_with?("[") && body_stripped.end_with?("]"))
          raise JSON::ParserError, "Invalid JSON structure"
        end

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

      def build_rpc_response(env, result, request_id, session_id)
        headers = { "Mcp-Session-Id" => session_id }
        if client_accepts_sse?(env)
          sse_rpc_response(result, request_id, headers, session_id: session_id)
        else
          json_rpc_response(result, request_id, headers)
        end
      end

      def build_protocol_error_response(env, error, session_id: nil)
        if client_accepts_sse?(env)
          sse_error_response(error.request_id, error.code, error.message, error.details, session_id: session_id)
        else
          json_error_response(error.request_id, error.code, error.message, error.details)
        end
      end

      def client_accepts_sse?(env)
        accept = env["HTTP_ACCEPT"] || ""
        accept.include?("text/event-stream")
      end

      def format_sse_event(data, type, event_id, retry_ms: nil)
        lines = []
        lines << "id: #{event_id}" if event_id
        lines << "event: #{type}" if type
        lines << "retry: #{retry_ms}" if retry_ms
        lines << "data: #{data}"
        lines << ""
        "#{lines.join("\n")}\n"
      end

      def sse_rpc_response(result, request_id, headers = {}, session_id: nil)
        response = { jsonrpc: "2.0", id: request_id, result: result }
        event_data = response.to_json
        stream_id = generate_sse_stream_id(session_id, :post)

        # Priming event per MCP spec: event ID + empty data field
        prime_event_id = @event_store.store_event("", nil, session_id: session_id, stream_id: stream_id)
        prime_event = "id: #{prime_event_id}\ndata:\n\n"

        # Actual response event
        event_id = @event_store.store_event(event_data, "message", session_id: session_id, stream_id: stream_id)
        sse_event = format_sse_event(event_data, "message", event_id)

        response_headers = {
          "Content-Type" => "text/event-stream",
          "Cache-Control" => "no-cache",
          "Connection" => "keep-alive",
          "X-Accel-Buffering" => "no"
        }.merge(headers)

        [200, response_headers, [prime_event, sse_event]]
      end

      def sse_error_response(id, code, err_message, data = nil, session_id: nil)
        error_obj = { code: code, message: err_message }
        error_obj[:data] = data if data
        response = { jsonrpc: "2.0", id: id, error: error_obj }
        event_data = response.to_json
        stream_id = generate_sse_stream_id(session_id, :post)

        # Priming event per MCP spec
        prime_event_id = @event_store.store_event("", nil, session_id: session_id, stream_id: stream_id)
        prime_event = "id: #{prime_event_id}\ndata:\n\n"

        event_id = @event_store.store_event(event_data, "message", session_id: session_id, stream_id: stream_id)
        sse_event = format_sse_event(event_data, "message", event_id)

        response_headers = {
          "Content-Type" => "text/event-stream",
          "Cache-Control" => "no-cache"
        }

        [200, response_headers, [prime_event, sse_event]]
      end

      def not_found_response(message = "Not Found")
        [404, { "Content-Type" => "text/plain" }, [message]]
      end

      def bad_request_response(message = "Bad Request")
        [400, { "Content-Type" => "text/plain" }, [message]]
      end

      def forbidden_response(message = "Forbidden")
        error = { jsonrpc: "2.0", error: { code: -32_600, message: message } }
        [403, { "Content-Type" => "application/json" }, [error.to_json]]
      end

      def method_not_allowed_response(allowed_methods)
        [405, { "Content-Type" => "text/plain", "Allow" => allowed_methods.join(", ") },
         ["Method Not Allowed"]]
      end

      def not_acceptable_response(message = "Not Acceptable")
        [406, { "Content-Type" => "text/plain" }, [message]]
      end

      # Validates the MCP-Protocol-Version header per spec.
      # Returns nil if valid, or a 400 Rack response if unsupported.
      def validate_protocol_version_header(env)
        version = env["HTTP_MCP_PROTOCOL_VERSION"]
        return nil if version.nil? # Backwards compatibility: assume 2025-03-26

        unless VectorMCP::Server::SUPPORTED_PROTOCOL_VERSIONS.include?(version)
          return bad_request_response("Unsupported MCP-Protocol-Version: #{version}")
        end

        nil
      end

      def valid_post_accept?(env)
        accept = env["HTTP_ACCEPT"]
        return true if accept.nil? || accept.strip.empty?
        return true if accept.include?("*/*")

        # MCP spec: client MUST include both application/json AND text/event-stream
        accept.include?("application/json") && accept.include?("text/event-stream")
      end

      def valid_get_accept?(env)
        accept = env["HTTP_ACCEPT"]
        return true if accept.nil? || accept.strip.empty?

        accept.include?("text/event-stream") || accept.include?("*/*")
      end

      # Validates the Origin header for security.
      #
      # Matches are checked both exactly and as prefix (so that
      # +http://localhost+ in the allowed list matches +http://localhost:3000+).
      #
      # Requests without an Origin header are allowed through because they
      # originate from non-browser contexts (curl, server-to-server, etc.).
      #
      # @param env [Hash] The Rack environment
      # @return [Boolean] True if origin is allowed, false otherwise
      def valid_origin?(env)
        return true if @allowed_origins.include?("*")

        origin = env["HTTP_ORIGIN"]
        return true if origin.nil? # Allow requests without Origin header (e.g., server-to-server)

        @allowed_origins.any? do |allowed|
          origin == allowed || origin.start_with?("#{allowed}:")
        end
      end

      # Logging and error handling
      def log_request_completion(method, path, start_time, status)
        duration = Time.now - start_time
        logger.info { "#{method} #{path} #{status} (#{(duration * 1000).round(2)}ms)" }
      end

      def handle_request_error(method, path, error)
        logger.error { "Request processing error for #{method} #{path}: #{error.message}" }
        [500, { "Content-Type" => "text/plain" }, ["Internal Server Error"]]
      end

      def build_transport_context(env, method, path, start_time)
        request_context = VectorMCP::RequestContext.from_rack_env(env, "http_stream")

        VectorMCP::Middleware::Context.new(
          operation_type: :transport,
          operation_name: "#{method} #{path}",
          params: request_context.to_h,
          session: nil,
          server: @server,
          metadata: {
            start_time: start_time,
            path: path,
            method: method
          }
        )
      end

      def execute_transport_hooks(hook_type, context)
        return context unless @server.respond_to?(:middleware_manager) && @server.middleware_manager

        @server.middleware_manager.execute_hooks(hook_type, context)
      end

      def handle_fatal_error(error)
        logger.fatal { "Fatal error in HttpStream transport: #{error.message}" }
        exit(1)
      end

      # Request tracking helpers for server-initiated requests

      # Sets up tracking for an outgoing request.
      #
      # @param request_id [String] The request ID to track
      # @return [void]
      def setup_request_tracking(request_id)
        @outgoing_request_ivars[request_id] = Concurrent::IVar.new
      end

      # Waits for a response to an outgoing request.
      #
      # @param request_id [String] The request ID to wait for
      # @param method [String] The request method name
      # @param timeout [Numeric] How long to wait
      # @return [Hash] The response data
      # @raise [VectorMCP::SamplingTimeoutError] if timeout occurs
      def wait_for_response(request_id, method, timeout)
        ivar = @outgoing_request_ivars[request_id]
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
          raise VectorMCP::SamplingError,
                "Malformed response for '#{method}' request (ID: #{request_id}): missing 'result' field. Response: #{response.inspect}"
        end

        response[:result]
      end

      # Cleans up tracking for a request.
      #
      # @param request_id [String] The request ID to clean up
      # @return [void]
      def cleanup_request_tracking(request_id)
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

        ivar = @outgoing_request_ivars[request_id]

        unless ivar
          logger.debug { "Received response for request ID #{request_id} but no thread is waiting (likely timed out)" }
          return
        end

        # Convert keys to symbols for consistency and put response in IVar
        response_data = deep_transform_keys(message, &:to_sym)
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
      def deep_transform_keys(obj, &)
        transform_object_keys(obj, &)
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
        @allowed_origins = options[:allowed_origins] || DEFAULT_ALLOWED_ORIGINS
        @mounted = options.fetch(:mounted, false)

        warn_on_permissive_origins if @allowed_origins.include?("*")
      end

      # Logs a security warning when wildcard origin is configured.
      def warn_on_permissive_origins
        logger.warn do
          "[SECURITY] allowed_origins includes '*', which permits cross-origin requests from any website. " \
            "This is not recommended for production. Specify explicit origins instead."
        end
      end

      # Initialize core HTTP stream components
      def initialize_components
        @session_manager = HttpStream::SessionManager.new(self, @session_timeout)
        @event_store = HttpStream::EventStore.new(@event_retention)
        @stream_handler = HttpStream::StreamHandler.new(self)
      end

      # Initialize request tracking system and ID generation for server-initiated requests
      def initialize_request_tracking
        @outgoing_request_ivars = Concurrent::Hash.new
        initialize_request_id_generation
      end

      # Initialize thread-safe request ID generation components
      def initialize_request_id_generation
        # Thread-safe request ID generation - avoid Fiber/Enumerator which can't cross threads
        @request_id_base = "vecmcp_http_#{Process.pid}_#{SecureRandom.hex(4)}"
        @request_id_counter = Concurrent::AtomicFixnum.new(0)
      end

      def generate_sse_stream_id(session_id, origin)
        session_label = session_id || "anonymous"
        "#{session_label}-#{origin}-#{SecureRandom.hex(4)}"
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

        @outgoing_request_ivars.clear
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
