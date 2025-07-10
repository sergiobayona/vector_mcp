# frozen_string_literal: true

require "json"
require "securerandom"
require "puma"
require "rack"
require "concurrent-ruby"

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
    class HttpStream
      attr_reader :logger, :server, :host, :port, :path_prefix

      # Default configuration values
      DEFAULT_HOST = "localhost"
      DEFAULT_PORT = 8000
      DEFAULT_PATH_PREFIX = "/mcp"
      DEFAULT_SESSION_TIMEOUT = 300 # 5 minutes
      DEFAULT_EVENT_RETENTION = 100 # Keep last 100 events for resumability

      # Initializes a new HTTP Stream transport.
      #
      # @param server [VectorMCP::Server] The server instance that will handle messages
      # @param options [Hash] Configuration options for the transport
      # @option options [String] :host ("localhost") The hostname or IP to bind to
      # @option options [Integer] :port (8000) The port to listen on
      # @option options [String] :path_prefix ("/mcp") The base path for HTTP endpoints
      # @option options [Integer] :session_timeout (300) Session timeout in seconds
      # @option options [Integer] :event_retention (100) Number of events to retain for resumability
      def initialize(server, options = {})
        @server = server
        @logger = server.logger
        @host = options[:host] || DEFAULT_HOST
        @port = options[:port] || DEFAULT_PORT
        @path_prefix = normalize_path_prefix(options[:path_prefix] || DEFAULT_PATH_PREFIX)
        @session_timeout = options[:session_timeout] || DEFAULT_SESSION_TIMEOUT
        @event_retention = options[:event_retention] || DEFAULT_EVENT_RETENTION

        # Initialize components
        @session_manager = HttpStream::SessionManager.new(self, @session_timeout)
        @event_store = HttpStream::EventStore.new(@event_retention)
        @stream_handler = HttpStream::StreamHandler.new(self)

        @puma_server = nil
        @running = false

        logger.info { "HttpStream transport initialized: #{@host}:#{@port}#{@path_prefix}" }
      end

      # Starts the HTTP Stream transport.
      # This method will block until the server is stopped.
      #
      # @return [void]
      # @raise [StandardError] if there's a fatal error during server startup
      def run
        logger.info { "Starting HttpStream transport server on #{@host}:#{@port}#{@path_prefix}" }

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

        logger.debug { "Processing #{method} #{path}" }

        response = route_request(path, method, env)
        log_request_completion(method, path, start_time, response[0])
        response
      rescue StandardError => e
        handle_request_error(method, path, e)
      end

      # Sends a notification to a specific session.
      #
      # @param session_id [String] The target session ID
      # @param method [String] The notification method name
      # @param params [Hash, Array, nil] The notification parameters
      # @return [Boolean] True if notification was sent successfully
      def send_notification(session_id, method, params = nil)
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

      # Stops the transport and cleans up resources.
      #
      # @return [void]
      def stop
        logger.info { "Stopping HttpStream transport" }
        @running = false
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

        logger.info { "HttpStream server starting on #{@host}:#{@port}" }
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
        session = @session_manager.get_or_create_session(session_id)

        request_body = read_request_body(env)
        message = parse_json_message(request_body)

        result = @server.handle_message(message, session.context, session.id)

        # Set session ID header in response
        headers = { "Mcp-Session-Id" => session.id }
        json_response(result, headers)
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

        session = @session_manager.get_session(session_id)
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

      # Parses JSON message from request body
      #
      # @param body [String] The request body
      # @return [Hash] The parsed JSON message
      # @raise [JSON::ParserError] if JSON is invalid
      def parse_json_message(body)
        JSON.parse(body)
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

      def method_not_allowed_response(allowed_methods)
        [405, { "Content-Type" => "text/plain", "Allow" => allowed_methods.join(", ") },
         ["Method Not Allowed"]]
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

      def handle_fatal_error(error)
        logger.fatal { "Fatal error in HttpStream transport: #{error.message}" }
        exit(1)
      end
    end
  end
end
