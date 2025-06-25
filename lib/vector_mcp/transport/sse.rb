# frozen_string_literal: true

require "json"
require "securerandom"
require "puma"
require "rack"
require "concurrent-ruby"

require_relative "../errors"
require_relative "../util"
require_relative "../session"
require_relative "../browser"
require_relative "sse/client_connection"
require_relative "sse/stream_manager"
require_relative "sse/message_handler"
require_relative "sse/puma_config"

module VectorMCP
  module Transport
    # Implements the Model Context Protocol transport over HTTP using Server-Sent Events (SSE)
    # for server-to-client messages and HTTP POST for client-to-server messages.
    # This transport uses Puma as the HTTP server with Ruby threading for concurrency.
    #
    # It provides two main HTTP endpoints:
    # 1.  SSE Endpoint (`<path_prefix>/sse`): Clients connect here via GET to establish an SSE stream.
    #     The server sends an initial `event: endpoint` with a unique URL for the client to POST messages back.
    #     Subsequent messages from the server (responses, notifications) are sent as `event: message`.
    # 2.  Message Endpoint (`<path_prefix>/message`): Clients POST JSON-RPC messages here.
    #     The `session_id` (obtained from the SSE endpoint event) must be included as a query parameter.
    #     The server responds with a 202 Accepted and then sends the actual JSON-RPC response/error
    #     asynchronously over the client's established SSE stream.
    #
    # @example Basic Usage with a Server
    #   server = VectorMCP::Server.new("my-sse-server")
    #   # ... register tools, resources, prompts ...
    #   transport = VectorMCP::Transport::SSE.new(server, port: 8080)
    #   server.run(transport: transport)
    #
    # @attr_reader logger [Logger] The logger instance, shared with the server.
    # @attr_reader server [VectorMCP::Server] The server instance this transport is bound to.
    # @attr_reader host [String] The hostname or IP address the server will bind to.
    # @attr_reader port [Integer] The port number the server will listen on.
    # @attr_reader path_prefix [String] The base URL path for MCP endpoints (e.g., "/mcp").
    class SSE
      attr_reader :logger, :server, :host, :port, :path_prefix

      # Initializes a new SSE transport.
      #
      # @param server [VectorMCP::Server] The server instance that will handle messages.
      # @param options [Hash] Configuration options for the transport.
      # @option options [String] :host ("localhost") The hostname or IP to bind to.
      # @option options [Integer] :port (8000) The port to listen on.
      # @option options [String] :path_prefix ("/mcp") The base path for HTTP endpoints.
      def initialize(server, options = {})
        @server = server
        @logger = server.logger
        @host = options[:host] || "localhost"
        @port = options[:port] || 8000
        prefix = options[:path_prefix] || "/mcp"
        @path_prefix = prefix.start_with?("/") ? prefix : "/#{prefix}"
        @path_prefix = @path_prefix.delete_suffix("/")
        @sse_path = "#{@path_prefix}/sse"
        @message_path = "#{@path_prefix}/message"

        # Thread-safe client storage using concurrent-ruby
        @clients = Concurrent::Hash.new
        @session = nil # Global session for this transport instance, initialized in run
        @puma_server = nil
        @running = false

        # Initialize browser automation server
        @browser_server = VectorMCP::Browser::HttpServer.new(logger)

        logger.debug { "SSE Transport initialized with prefix: #{@path_prefix}, SSE path: #{@sse_path}, Message path: #{@message_path}" }
      end

      # Starts the SSE transport, creating a shared session and launching the Puma server.
      # This method will block until the server is stopped (e.g., via SIGINT/SIGTERM).
      #
      # @return [void]
      # @raise [StandardError] if there's a fatal error during server startup.
      def run
        logger.info("Starting server with Puma SSE transport on #{@host}:#{@port}")
        create_session
        start_puma_server
      rescue StandardError => e
        handle_fatal_error(e)
      end

      # --- Rack-compatible #call method ---

      # Handles incoming HTTP requests. This is the entry point for the Rack application.
      # It routes requests to the appropriate handler based on the path.
      #
      # @param env [Hash] The Rack environment hash.
      # @return [Array(Integer, Hash, Object)] A standard Rack response triplet: [status, headers, body].
      def call(env)
        start_time = Time.now
        path = env["PATH_INFO"]
        http_method = env["REQUEST_METHOD"]
        logger.info "Received #{http_method} request for #{path}"

        status, headers, body = route_request(path, env)

        log_response(http_method, path, start_time, status)
        [status, headers, body]
      rescue StandardError => e
        handle_call_error(http_method, path, e)
      end

      # --- Public methods for Server to send notifications ---

      # Sends a JSON-RPC notification to a specific client session via its SSE stream.
      #
      # @param session_id [String] The ID of the client session to send the notification to.
      # @param method [String] The method name of the notification.
      # @param params [Hash, Array, nil] The parameters for the notification (optional).
      # @return [Boolean] True if the message was successfully enqueued, false otherwise (e.g., client not found).
      def send_notification(session_id, method, params = nil)
        message = { jsonrpc: "2.0", method: method }
        message[:params] = params if params

        client_conn = @clients[session_id]
        return false unless client_conn

        StreamManager.enqueue_message(client_conn, message)
      end

      # Broadcasts a JSON-RPC notification to all currently connected client sessions.
      #
      # @param method [String] The method name of the notification.
      # @param params [Hash, Array, nil] The parameters for the notification (optional).
      # @return [void]
      def broadcast_notification(method, params = nil)
        logger.debug { "Broadcasting notification '#{method}' to #{@clients.size} client(s)" }
        message = { jsonrpc: "2.0", method: method }
        message[:params] = params if params

        @clients.each_value do |client_conn|
          StreamManager.enqueue_message(client_conn, message)
        end
      end

      # Provides compatibility for tests that expect a `build_rack_app` helper.
      # Since the transport itself is a Rack app (defines `#call`), it returns `self`.
      #
      # @param session [VectorMCP::Session, nil] An optional session to persist for testing.
      # @return [self] The transport instance itself.
      def build_rack_app(session = nil)
        @session = session if session
        self
      end

      # Stops the transport and cleans up resources
      def stop
        @running = false
        cleanup_clients
        @puma_server&.stop
        logger.info("SSE transport stopped")
      end

      # Check if Chrome extension is connected
      def extension_connected?
        @browser_server.extension_connected?
      end

      # Get browser automation statistics
      def browser_stats
        {
          extension_connected: extension_connected?,
          command_queue_stats: @browser_server.command_queue.stats
        }
      end

      # --- Private methods ---
      private

      # Creates a single, shared {VectorMCP::Session} instance for this transport run.
      # All client interactions will use this session context.
      def create_session
        @session = VectorMCP::Session.new(server, self, id: SecureRandom.uuid)
      end

      # Starts the Puma HTTP server.
      def start_puma_server
        @puma_server = Puma::Server.new(build_rack_app)
        puma_config = PumaConfig.new(@host, @port, logger)
        puma_config.configure(@puma_server)

        @running = true
        setup_signal_traps

        logger.info("Puma server starting on #{@host}:#{@port}")
        @puma_server.run.join # This blocks until server stops
        logger.info("Puma server stopped.")
      ensure
        cleanup_clients
        @session = nil
        logger.info("SSE transport and resources shut down.")
      end

      # Sets up POSIX signal traps for graceful server shutdown (INT, TERM).
      def setup_signal_traps
        Signal.trap("INT") do
          logger.info("SIGINT received, stopping server...")
          stop
        end
        Signal.trap("TERM") do
          logger.info("SIGTERM received, stopping server...")
          stop
        end
      end

      # Cleans up resources for all connected clients on server shutdown.
      def cleanup_clients
        logger.info("Cleaning up #{@clients.size} client connection(s)...")
        @clients.each_value(&:close)
        @clients.clear
      end

      # Handles fatal errors during server startup or main run loop.
      def handle_fatal_error(error)
        logger.fatal("Fatal error in SSE transport: #{error.message}\n#{error.backtrace.join("\n")}")
        exit(1)
      end

      # Routes an incoming request to the appropriate handler based on its path.
      def route_request(path, env)
        case path
        when @sse_path
          handle_sse_connection(env)
        when @message_path
          handle_message_post(env)
        when "/"
          [200, { "Content-Type" => "text/plain" }, ["VectorMCP Server OK"]]
        else
          # Check if this is a browser automation endpoint
          if path.start_with?("/browser/")
            @browser_server.handle_browser_request(path, env)
          else
            [404, { "Content-Type" => "text/plain" }, ["Not Found"]]
          end
        end
      end

      # Logs the response details including status, method, path, and duration.
      def log_response(method, path, start_time, status)
        duration = format("%.4f", Time.now - start_time)
        logger.info "Responded #{status} to #{method} #{path} in #{duration}s"
      end

      # Generic error handler for exceptions occurring within the `#call` method's request processing.
      def handle_call_error(method, path, error)
        error_context = method || "UNKNOWN_METHOD"
        path_context = path || "UNKNOWN_PATH"
        backtrace = error.backtrace.join("\n")
        logger.error("Error during SSE request processing for #{error_context} #{path_context}: #{error.message}\n#{backtrace}")
        [500, { "Content-Type" => "text/plain", "connection" => "close" }, ["Internal Server Error"]]
      end

      # Handles a new client connection to the SSE endpoint.
      def handle_sse_connection(env)
        return invalid_method_response(env) unless env["REQUEST_METHOD"] == "GET"

        session_id = SecureRandom.uuid
        logger.info("New SSE client connected: #{session_id}")

        # Create client connection
        client_conn = ClientConnection.new(session_id, logger)
        @clients[session_id] = client_conn

        # Build message POST URL for this client
        message_post_url = build_post_url(session_id)
        logger.debug("Client #{session_id} should POST messages to: #{message_post_url}")

        # Set up SSE stream
        headers = sse_headers
        body = StreamManager.create_sse_stream(client_conn, message_post_url, logger)

        [200, headers, body]
      end

      # Handles incoming POST requests containing JSON-RPC messages from clients.
      def handle_message_post(env)
        return invalid_post_method_response(env) unless env["REQUEST_METHOD"] == "POST"

        session_id = extract_session_id(env["QUERY_STRING"])
        unless session_id
          return error_response(nil, VectorMCP::InvalidRequestError.new("Missing session_id parameter").code,
                                "Missing session_id parameter")
        end

        client_conn = @clients[session_id]
        return error_response(nil, VectorMCP::NotFoundError.new("Invalid session_id").code, "Invalid session_id") unless client_conn

        MessageHandler.new(@server, @session, logger).handle_post_message(env, client_conn)
      end

      # Helper methods
      def invalid_method_response(env)
        method = env["REQUEST_METHOD"]
        logger.warn("Received non-GET request on SSE endpoint: #{method}")
        [405, { "Content-Type" => "text/plain", "Allow" => "GET" }, ["Method Not Allowed. Only GET is supported for SSE endpoint."]]
      end

      def invalid_post_method_response(env)
        method = env["REQUEST_METHOD"]
        logger.warn("Received non-POST request on message endpoint: #{method}")
        [405, { "Content-Type" => "text/plain", "Allow" => "POST" }, ["Method Not Allowed"]]
      end

      def sse_headers
        {
          "Content-Type" => "text/event-stream",
          "Cache-Control" => "no-cache",
          "Connection" => "keep-alive",
          "X-Accel-Buffering" => "no"
        }
      end

      def build_post_url(session_id)
        "#{@message_path}?session_id=#{session_id}"
      end

      def extract_session_id(query_string)
        return nil unless query_string

        URI.decode_www_form(query_string).to_h["session_id"]
      end

      def error_response(id, code, message, data = nil)
        status = case code
                 when -32_700, -32_600, -32_602 then 400
                 when -32_601, -32_001 then 404
                 else 500
                 end
        error_payload = { code: code, message: message }
        error_payload[:data] = data if data
        body = { jsonrpc: "2.0", id: id, error: error_payload }.to_json
        [status, { "Content-Type" => "application/json" }, [body]]
      end
    end
  end
end
