# frozen_string_literal: true

require "json"
require "securerandom"
require "async"
require "async/io"
require "async/http/endpoint"
require "async/http/body/writable"
require "falcon/server"
require "falcon/endpoint"

require_relative "../errors"
require_relative "../util"
require_relative "../session" # Make sure session is loaded

module VectorMCP
  module Transport
    # Implements the Model Context Protocol transport over HTTP using Server-Sent Events (SSE)
    # for server-to-client messages and HTTP POST for client-to-server messages.
    # This transport uses the `async` and `falcon` gems for an event-driven, non-blocking I/O model.
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
    #   server.run(transport: transport) # or transport.run if server not managing transport lifecycle
    #
    # @attr_reader logger [Logger] The logger instance, shared with the server.
    # @attr_reader server [VectorMCP::Server] The server instance this transport is bound to.
    # @attr_reader host [String] The hostname or IP address the server will bind to.
    # @attr_reader port [Integer] The port number the server will listen on.
    # @attr_reader path_prefix [String] The base URL path for MCP endpoints (e.g., "/mcp").
    class SSE
      attr_reader :logger, :server, :host, :port, :path_prefix

      # Internal structure to hold client connection state, including its unique ID,
      # a message queue for outbound messages, and the Async task managing its stream.
      # @!attribute id [r] String The unique ID for this client connection (session_id).
      # @!attribute queue [r] Async::Queue The queue for messages to be sent to this client.
      # @!attribute task [rw] Async::Task The task managing the SSE stream for this client.
      ClientConnection = Struct.new(:id, :queue, :task)

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

        @clients = {} # Thread-safe storage: session_id -> ClientConnection
        @clients_mutex = Mutex.new
        @session = nil # Global session for this transport instance, initialized in run
        logger.debug { "SSE Transport initialized with prefix: #{@path_prefix}, SSE path: #{@sse_path}, Message path: #{@message_path}" }
      end

      # Starts the SSE transport, creating a shared session and launching the Falcon server.
      # This method will block until the server is stopped (e.g., via SIGINT/SIGTERM).
      #
      # @return [void]
      # @raise [StandardError] if there's a fatal error during server startup.
      def run
        logger.info("Starting server with async SSE transport on #{@host}:#{@port}")
        create_session
        start_async_server
      rescue StandardError => e
        handle_fatal_error(e) # Logs and exits
      end

      # --- Rack-compatible #call method ---

      # Handles incoming HTTP requests. This is the entry point for the Rack application.
      # It routes requests to the appropriate handler based on the path.
      #
      # @param env [Hash, Async::HTTP::Request] The Rack environment hash or an Async HTTP request object.
      # @return [Array(Integer, Hash, Object)] A standard Rack response triplet: [status, headers, body].
      #   The body is typically an `Async::HTTP::Body::Writable` for SSE or an Array of strings.
      def call(env)
        start_time = Time.now
        path, http_method = extract_path_and_method(env)
        logger.info "Received #{http_method} request for #{path}"

        status, headers, body = route_request(path, env)

        log_response(http_method, path, start_time, status)
        [status, headers, body]
      rescue StandardError => e
        # Generic error handling for issues within the call chain itself
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
        enqueue_message(session_id, message)
      end

      # Broadcasts a JSON-RPC notification to all currently connected client sessions.
      #
      # @param method [String] The method name of the notification.
      # @param params [Hash, Array, nil] The parameters for the notification (optional).
      # @return [void]
      def broadcast_notification(method, params = nil)
        logger.debug { "Broadcasting notification '#{method}' to #{@clients.size} client(s)" }
        @clients_mutex.synchronize do
          @clients.each_key do |sid|
            send_notification(sid, method, params)
          end
        end
      end

      # Provides compatibility for tests that expect a `build_rack_app` helper.
      # Since the transport itself is a Rack app (defines `#call`), it returns `self`.
      #
      # @param session [VectorMCP::Session, nil] An optional session to persist for testing.
      # @return [self] The transport instance itself.
      def build_rack_app(session = nil)
        @session = session if session # Used by some tests to inject a specific session
        self
      end

      # --- Private methods ---
      private

      # --- Initialization and Server Lifecycle Helpers ---

      # Creates a single, shared {VectorMCP::Session} instance for this transport run.
      # All client interactions will use this session context.
      # @api private
      # @return [void]
      def create_session
        @session = VectorMCP::Session.new(
          server_info: server.server_info,
          server_capabilities: server.server_capabilities,
          protocol_version: server.protocol_version
        )
      end

      # Starts the Falcon async HTTP server.
      # @api private
      # @return [void]
      def start_async_server
        endpoint = Falcon::Endpoint.parse("http://#{@host}:#{@port}")
        app = self # The transport instance itself is the Rack app

        Async do |task|
          setup_signal_traps(task)
          logger.info("Falcon server starting on #{endpoint.url}")
          falcon_server = Falcon::Server.new(Falcon::Server.middleware(app), endpoint)
          falcon_server.run # This blocks until server stops
          logger.info("Falcon server stopped.")
        ensure
          cleanup_clients
          @session = nil # Clear the session on shutdown
          logger.info("SSE transport and resources shut down.")
        end
      end

      # Sets up POSIX signal traps for graceful server shutdown (INT, TERM).
      # @api private
      # @param task [Async::Task] The parent async task to stop on signal.
      # @return [void]
      def setup_signal_traps(task)
        task.async do
          trap(:INT) do
            logger.info("SIGINT received, stopping server...")
            task.stop
          end
          trap(:TERM) do
            logger.info("SIGTERM received, stopping server...")
            task.stop
          end
        end
      end

      # Cleans up resources for all connected clients on server shutdown.
      # Closes their message queues and stops their async tasks.
      # @api private
      # @return [void]
      def cleanup_clients
        @clients_mutex.synchronize do
          logger.info("Cleaning up #{@clients.size} client connection(s)...")
          @clients.each_value do |conn|
            conn.queue&.close if conn.queue.respond_to?(:close)
            conn.task&.stop # Attempt to stop the client's streaming task
          end
          @clients.clear
        end
      end

      # Handles fatal errors during server startup or main run loop. Logs and exits.
      # @api private
      # @param error [StandardError] The fatal error.
      # @return [void] This method calls `exit(1)`.
      def handle_fatal_error(error)
        logger.fatal("Fatal error in SSE transport: #{error.message}\n#{error.backtrace.join("\n")}")
        exit(1)
      end

      # --- HTTP Request Routing and Basic Handling ---

      # Extracts the request path and HTTP method from the Rack `env` or `Async::HTTP::Request`.
      # @api private
      # @param env [Hash, Async::HTTP::Request] The request environment.
      # @return [Array(String, String)] The request path and HTTP method.
      def extract_path_and_method(env)
        if env.is_a?(Hash) # Rack env
          [env["PATH_INFO"], env["REQUEST_METHOD"]]
        else # Async::HTTP::Request
          [env.path, env.method]
        end
      end

      # Routes an incoming request to the appropriate handler based on its path.
      # @api private
      # @param path [String] The request path.
      # @param env [Hash, Async::HTTP::Request] The request environment.
      # @return [Array] A Rack response triplet.
      def route_request(path, env)
        case path
        when @sse_path
          handle_sse_connection(env, @session)
        when @message_path
          handle_message_post(env, @session)
        when "/" # Root path, useful for health checks
          [200, { "Content-Type" => "text/plain" }, ["VectorMCP Server OK"]]
        else
          [404, { "Content-Type" => "text/plain" }, ["Not Found"]]
        end
      end

      # Logs the response details including status, method, path, and duration.
      # @api private
      # @param method [String] The HTTP method of the request.
      # @param path [String] The request path.
      # @param start_time [Time] The time the request processing started.
      # @param status [Integer] The HTTP status code of the response.
      # @return [void]
      def log_response(method, path, start_time, status)
        duration = format("%.4f", Time.now - start_time)
        logger.info "Responded #{status} to #{method} #{path} in #{duration}s"
      end

      # Generic error handler for exceptions occurring within the `#call` method's request processing.
      # @api private
      # @param method [String, nil] The HTTP method, if known.
      # @param path [String, nil] The request path, if known.
      # @param error [StandardError] The error that occurred.
      # @return [Array] A 500 Internal Server Error Rack response.
      def handle_call_error(method, path, error)
        error_context = method || "UNKNOWN_METHOD"
        path_context  = path   || "UNKNOWN_PATH"
        backtrace = error.backtrace.join("\n")
        logger.error("Error during SSE request processing for #{error_context} #{path_context}: #{error.message}\n#{backtrace}")
        # Optional: for local debugging, print to console too
        begin
          warn "[DEBUG-SSE-Transport] Exception in #call: #{error.class}: #{error.message}\n\t#{error.backtrace.join("\n\t")}"
        rescue StandardError
          nil
        end
        [500, { "Content-Type" => "text/plain", "connection" => "close" }, ["Internal Server Error"]]
      end

      # --- SSE Connection Handling (`/sse` endpoint) ---

      # Handles a new client connection to the SSE endpoint.
      # Validates it's a GET request, sets up the SSE stream, and sends the initial endpoint event.
      # @api private
      # @param env [Hash, Async::HTTP::Request] The request environment.
      # @param _session [VectorMCP::Session] The shared server session (currently unused by this method but passed for consistency).
      # @return [Array] A Rack response triplet for the SSE stream (200 OK with SSE headers).
      # session is the shared server session, not a per-client one here
      def handle_sse_connection(env, _session)
        return invalid_method_response(env) unless get_request?(env)

        session_id   = SecureRandom.uuid # This is the *client's* unique session ID for this SSE connection
        client_queue = Async::Queue.new

        headers          = default_sse_headers
        message_post_url = build_post_url(session_id) # URL for this client to POST messages to

        logger.info("New SSE client connected: #{session_id}")
        logger.debug("Client #{session_id} should POST messages to: #{message_post_url}")

        client_conn, body = create_client_connection(session_id, client_queue)
        stream_client_messages(client_conn, client_queue, body, message_post_url) # Starts async task

        [200, headers, body] # Return SSE stream
      end

      # Helper to check if the request is a GET.
      # @api private
      def get_request?(env)
        request_method(env) == "GET"
      end

      # Returns a 405 Method Not Allowed response, used by SSE endpoint for non-GET requests.
      # @api private
      def invalid_method_response(env)
        method = request_method(env)
        logger.warn("Received non-GET request on SSE endpoint from #{begin
          env["REMOTE_ADDR"]
        rescue StandardError
          "unknown"
        end}: #{method} #{begin
          env["PATH_INFO"]
        rescue StandardError
          ""
        end}")
        [405, { "Content-Type" => "text/plain", "Allow" => "GET" }, ["Method Not Allowed. Only GET is supported for SSE endpoint."]]
      end

      # Provides default HTTP headers for an SSE stream.
      # @api private
      # @return [Hash] SSE-specific HTTP headers.
      def default_sse_headers
        {
          "Content-Type" => "text/event-stream",
          "Cache-Control" => "no-cache", # Important for SSE
          "Connection" => "keep-alive",
          "X-Accel-Buffering" => "no" # Disable buffering in proxies like Nginx
        }
      end

      # Constructs the unique URL that a specific client should use to POST messages back to the server.
      # @api private
      # @param session_id [String] The client's unique session ID for the SSE connection.
      # @return [String] The full URL for posting messages.
      def build_post_url(session_id)
        # Assuming server runs behind a proxy that sets X-Forwarded-Proto and X-Forwarded-Host
        # For simplicity, this example constructs a relative path.
        # In a production setup, you might want to construct an absolute URL.
        "#{@message_path}?session_id=#{session_id}"
      end

      # Creates a new {ClientConnection} struct and an `Async::HTTP::Body::Writable` for the SSE stream.
      # @api private
      # @param session_id [String] The client's unique session ID.
      # @param client_queue [Async::Queue] The message queue for this client.
      # @return [Array(ClientConnection, Async::HTTP::Body::Writable)] The connection object and writable body.
      def create_client_connection(session_id, client_queue)
        client_conn = ClientConnection.new(session_id, client_queue, nil) # Task will be set later
        body        = Async::HTTP::Body::Writable.new # For streaming SSE events
        [client_conn, body]
      end

      # Starts an asynchronous task to stream messages from a client's queue to its SSE connection.
      # Handles client disconnections and cleans up resources.
      # @api private
      # @param client_conn [ClientConnection] The client's connection object.
      # @param queue [Async::Queue] The client's message queue.
      # @param body [Async::HTTP::Body::Writable] The writable body for the SSE stream.
      # @param post_url [String] The URL for the client to POST messages to (sent as initial event).
      # @return [void]
      def stream_client_messages(client_conn, queue, body, post_url)
        Async do |task| # This task manages the lifecycle of one SSE client connection
          prepare_client_stream(client_conn, task)
          begin
            send_endpoint_event(body, post_url) # First, tell client where to POST
            stream_queue_messages(queue, body, client_conn) # Then, stream messages from its queue
          rescue Async::Stop, IOError, Errno::EPIPE => e # Expected client disconnects
            logger.info("SSE client #{client_conn.id} disconnected (#{e.class.name}: #{e.message}).")
          rescue StandardError => e # Unexpected errors in this client's stream
            logger.error("Error in SSE streaming task for client #{client_conn.id}: #{e.class.name}: #{e.message}\n#{e.backtrace.join("\n")}")
          ensure
            finalize_client_stream(body, queue, client_conn)
          end
        end
      end

      # Prepares a client stream by associating the async task and registering the client.
      # @api private
      def prepare_client_stream(client_conn, task)
        client_conn.task = task
        @clients_mutex.synchronize { @clients[client_conn.id] = client_conn }
        logger.debug("SSE client stream prepared for #{client_conn.id}")
      end

      # Sends the initial `event: endpoint` to the client with the URL for POSTing messages.
      # @api private
      def send_endpoint_event(body, post_url)
        logger.debug("Sending 'endpoint' event with URL: #{post_url}")
        body.write("event: endpoint\ndata: #{post_url}\n\n")
      end

      # Continuously dequeues messages and writes them to the SSE stream.
      # Blocks until the queue is closed or an error occurs.
      # @api private
      def stream_queue_messages(queue, body, client_conn)
        logger.debug("Starting message streaming loop for SSE client #{client_conn.id}")
        while (message = queue.dequeue) # Blocks until message available or queue closed
          json_message = message.to_json
          logger.debug { "[SSE Client: #{client_conn.id}] Sending message: #{json_message.inspect}" }
          body.write("event: message\ndata: #{json_message}\n\n")
        end
        logger.debug("Message streaming loop ended for SSE client #{client_conn.id} (queue closed).")
      end

      # Finalizes a client stream by finishing the body, closing the queue, and unregistering the client.
      # @api private
      def finalize_client_stream(body, queue, client_conn)
        body.finish unless body.finished?
        queue.close if queue.respond_to?(:close) && (!queue.respond_to?(:closed?) || !queue.closed?)
        @clients_mutex.synchronize { @clients.delete(client_conn.id) }
        logger.info("SSE client stream finalized and resources cleaned for #{client_conn.id}")
      end

      # --- Message POST Handling (`/message` endpoint) ---

      # Handles incoming POST requests containing JSON-RPC messages from clients.
      # @api private
      # @param env [Hash, Async::HTTP::Request] The request environment.
      # @param session [VectorMCP::Session] The shared server session.
      # @return [Array] A Rack response triplet (typically 202 Accepted or an error).
      def handle_message_post(env, session)
        return invalid_post_method_response(env) unless post_request?(env)

        raw_path   = build_raw_path(env)
        session_id = extract_session_id(raw_path)
        unless session_id
          return error_response(nil, VectorMCP::InvalidRequestError.new("Missing session_id parameter").code,
                                "Missing session_id parameter")
        end

        client_conn = fetch_client_connection(session_id)
        return error_response(nil, VectorMCP::NotFoundError.new("Invalid session_id").code, "Invalid session_id") unless client_conn

        request_body_str = read_request_body(env, session_id)
        if request_body_str.nil? || request_body_str.empty?
          return error_response(nil, VectorMCP::InvalidRequestError.new("Request body is empty or unreadable").code,
                                "Request body is empty or unreadable")
        end

        process_post_message(request_body_str, client_conn, session, session_id)
      end

      # Helper to check if the request is a POST.
      # @api private
      def post_request?(env)
        request_method(env) == "POST"
      end

      # Returns a 405 Method Not Allowed response for non-POST requests to the message endpoint.
      # @api private
      def invalid_post_method_response(env)
        method = request_method(env)
        logger.warn("Received non-POST request on message endpoint from #{begin
          env["REMOTE_ADDR"]
        rescue StandardError
          "unknown"
        end}: #{method} #{begin
          env["PATH_INFO"]
        rescue StandardError
          ""
        end}")
        [405, { "Content-Type" => "text/plain", "Allow" => "POST" }, ["Method Not Allowed"]]
      end

      # Builds the full raw path including query string from the request environment.
      # @api private
      # @param env [Hash, Async::HTTP::Request] The request environment.
      # @return [String] The raw path with query string.
      def build_raw_path(env)
        if env.is_a?(Hash) # Rack env
          query_string = env["QUERY_STRING"]
          query_suffix = query_string && !query_string.empty? ? "?#{query_string}" : ""
          env["PATH_INFO"] + query_suffix
        else # Async::HTTP::Request
          env.path # Async::HTTP::Request.path includes query string
        end
      end

      # Extracts the `session_id` query parameter from a raw path string.
      # @api private
      # @param raw_path [String] The path string, possibly including a query string.
      # @return [String, nil] The extracted session_id, or nil if not found.
      def extract_session_id(raw_path)
        query_str = URI(raw_path).query
        return nil unless query_str

        URI.decode_www_form(query_str).to_h["session_id"]
      end

      # Fetches an active {ClientConnection} based on session_id.
      # @api private
      # @param session_id [String] The client session ID.
      # @return [ClientConnection, nil] The connection object if found, otherwise nil.
      def fetch_client_connection(session_id)
        @clients_mutex.synchronize { @clients[session_id] }
      end

      # Reads the request body from the environment.
      # @api private
      # @param env [Hash, Async::HTTP::Request] The request environment.
      # @param session_id [String] The client session ID (for logging).
      # @return [String, nil] The request body as a string, or nil if unreadable/empty.
      def read_request_body(env, session_id)
        source = env.is_a?(Hash) ? env["rack.input"] : env.body # env.body is an Async::HTTP::Body
        body_str = source&.read
        logger.error("[POST Client: #{session_id}] Request body is empty or could not be read.") if body_str.nil? || body_str.empty?
        body_str
      end

      # Processes the JSON-RPC message from a POST request.
      # Parses, handles via server, and enqueues response/error to the client's SSE stream.
      # @api private
      # @return [Array] A Rack response triplet (typically 202 Accepted).
      def process_post_message(body_str, client_conn, session, _session_id)
        message = parse_json_body(body_str, client_conn.id) # Use client_conn.id for logging consistency
        # parse_json_body returns an error triplet if parsing fails and error was enqueued
        return message if message.is_a?(Array) && message.size == 3

        # If message is valid JSON, proceed to handle it with the server
        response_data = server.handle_message(message, session, client_conn.id) # Pass client_conn.id as session_id for server context

        # If handle_message returns data, it was a request needing a response.
        # If it was a notification, handle_message would typically return nil or not be called for POSTs.
        # Assuming POSTs are always requests needing a response pushed via SSE.
        if message["id"] # It's a request
          enqueue_formatted_response(client_conn, message["id"], response_data)
        else # It's a notification (client shouldn't POST notifications, but handle defensively)
          logger.warn("[POST Client: #{client_conn.id}] Received a notification via POST. Ignoring response_data for notifications.")
        end

        # Always return 202 Accepted for valid POSTs that are being processed asynchronously.
        [202, { "Content-Type" => "application/json" }, [{ status: "accepted", id: message["id"] }.to_json]]
      rescue VectorMCP::ProtocolError => e
        # Errors from server.handle_message (application-level protocol errors)
        # rubocop:disable Layout/LineLength
        logger.error("[POST Client: #{client_conn.id}] Protocol Error during message handling: #{e.message} (Code: #{e.code}), Details: #{e.details.inspect}")
        # rubocop:enable Layout/LineLength
        request_id = e.request_id || message&.fetch("id", nil)
        enqueue_error(client_conn, request_id, e.code, e.message, e.details)
        # Return an appropriate HTTP error response for the POST request itself
        error_response(request_id, e.code, e.message, e.details)
      rescue StandardError => e
        # Unexpected errors during server.handle_message
        logger.error("[POST Client: #{client_conn.id}] Unhandled Error during message processing: #{e.message}\n#{e.backtrace.join("\n")}")
        request_id = message&.fetch("id", nil)
        details = { details: e.message }
        enqueue_error(client_conn, request_id, -32_603, "Internal server error", details)
        # Return a 500 Internal Server Error response for the POST request
        error_response(request_id, -32_603, "Internal server error", details)
      end

      # Parses the JSON body of a POST request. Handles JSON::ParserError by enqueuing an error
      # to the client and returning a Rack error response triplet.
      # @api private
      # @param body_str [String] The JSON string from the request body.
      # @param client_session_id [String] The client's session ID for logging and error enqueuing.
      # @return [Hash, Array] Parsed JSON message as a Hash, or a Rack error triplet if parsing failed.
      def parse_json_body(body_str, client_session_id)
        JSON.parse(body_str)
      rescue JSON::ParserError => e
        logger.error("[POST Client: #{client_session_id}] JSON Parse Error: #{e.message} for body: #{body_str.inspect}")
        # Try to get original request ID for error response, even from invalid JSON
        malformed_id = VectorMCP::Util.extract_id_from_invalid_json(body_str)
        # Enqueue error to client's SSE stream
        target_client = fetch_client_connection(client_session_id) # Re-fetch in case it's needed
        enqueue_error(target_client, malformed_id, -32_700, "Parse error") if target_client
        # Return a Rack error response for the POST itself
        error_response(malformed_id, -32_700, "Parse error")
      end

      # --- Message Enqueuing and Formatting Helpers (Private) ---

      # Enqueues a message hash to a specific client's outbound queue.
      # @api private
      # @param session_id [String] The target client's session ID.
      # @param message_hash [Hash] The JSON-RPC message (request, response, or notification) to send.
      # @return [Boolean] True if enqueued, false if client not found.
      def enqueue_message(session_id, message_hash)
        client_conn = @clients_mutex.synchronize { @clients[session_id] }
        if client_conn&.queue && (!client_conn.queue.respond_to?(:closed?) || !client_conn.queue.closed?)
          logger.debug { "[SSE Enqueue Client: #{session_id}] Queuing message: #{message_hash.inspect}" }
          client_conn.queue.enqueue(message_hash)
          true
        else
          logger.warn("Cannot enqueue message for session_id #{session_id}: Client queue not found or closed.")
          false
        end
      end

      # Formats a successful JSON-RPC response and enqueues it.
      # @api private
      def enqueue_formatted_response(client_conn, request_id, result_data)
        response = { jsonrpc: "2.0", id: request_id, result: result_data }
        enqueue_message(client_conn.id, response)
      end

      # Formats a JSON-RPC error and enqueues it.
      # @api private
      def enqueue_error(client_conn, request_id, code, message, data = nil)
        error_payload = format_error_payload(code, message, data)
        error_msg = { jsonrpc: "2.0", id: request_id, error: error_payload }
        enqueue_message(client_conn.id, error_msg) if client_conn # Only enqueue if client connection is valid
      end

      # Formats the `error` object for a JSON-RPC message.
      # @api private
      # @return [Hash] The error payload.
      def format_error_payload(code, message, data = nil)
        payload = { code: code, message: message }
        payload[:data] = data if data # `data` is optional
        payload
      end

      # Formats the body of an HTTP error response (for 4xx/5xx replies to POSTs).
      # @api private
      # @return [String] JSON string representing the error.
      def format_error_body(id, code, message, data = nil)
        { jsonrpc: "2.0", id: id, error: format_error_payload(code, message, data) }.to_json
      end

      # Creates a full Rack error response triplet (status, headers, body) for HTTP errors.
      # @api private
      # @return [Array] The Rack response.
      def error_response(id, code, message, data = nil)
        status = case code
                 when -32_700, -32_600, -32_602 then 400 # ParseError, InvalidRequest, InvalidParams
                 when -32_601, -32_001 then 404 # MethodNotFound, NotFoundError (custom)
                 else 500 # InternalError, ServerError, or any other
                 end
        [status, { "Content-Type" => "application/json" }, [format_error_body(id, code, message, data)]]
      end

      # Generic helper to extract HTTP method, used by get_request? and post_request?
      # @api private
      def request_method(env)
        env.is_a?(Hash) ? env["REQUEST_METHOD"] : env.method
      end
    end
  end
end
