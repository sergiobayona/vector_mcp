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
    # Server-Sent Events (SSE) transport for MCP using the 'async' ecosystem.
    # Implements the Rack call interface directly to avoid middleware issues with async env.
    class SSE
      attr_reader :logger, :server, :host, :port, :path_prefix

      # Internal structure to hold client connection state
      ClientConnection = Struct.new(:id, :queue, :task)

      def initialize(server, options = {})
        @server = server
        @logger = server.logger
        @host = options[:host] || "localhost"
        @port = options[:port] || 8000
        # Ensure path_prefix starts with / and doesn't end with /
        prefix = options[:path_prefix] || "/mcp"
        @path_prefix = prefix.start_with?("/") ? prefix : "/#{prefix}"
        @path_prefix = @path_prefix.delete_suffix("/")
        @sse_path = "#{@path_prefix}/sse"
        @message_path = "#{@path_prefix}/message"

        # Thread-safe storage for client connections (maps session_id -> ClientConnection)
        @clients = {}
        @clients_mutex = Mutex.new
        @session = nil # Will be initialized in run
        logger.debug { "SSE Transport initialized with prefix: #{@path_prefix}" }
      end

      def run
        logger.info("Starting server with async SSE transport on #{@host}:#{@port}")

        create_session
        start_async_server
      rescue StandardError => e
        handle_fatal_error(e)
      end

      # --- Rack-compatible call method --- #

      def call(env)
        start_time = Time.now
        path = http_method = nil
        path, http_method = extract_path_and_method(env)

        logger.info "Received #{http_method} request for #{path}"

        status, headers, body = route_request(path, env)

        log_response(http_method, path, start_time, status)

        [status, headers, body]
      rescue StandardError => e
        handle_call_error(http_method, path, e)
      end

      # --- Call helpers ---

      def extract_path_and_method(env)
        if env.is_a?(Hash)
          [env["PATH_INFO"], env["REQUEST_METHOD"]]
        else
          [env.path, env.method]
        end
      end

      def route_request(path, env)
        case path
        when @sse_path
          handle_sse_connection(env, @session)
        when @message_path
          handle_message_post(env, @session)
        when "/"
          [200, { "Content-Type" => "text/plain" }, ["VectorMCP Server OK"]]
        else
          [404, { "Content-Type" => "text/plain" }, ["Not Found"]]
        end
      end

      def log_response(method, path, start_time, status)
        duration = format("%.4f", Time.now - start_time)
        logger.info "Responded #{status} to #{method} #{path} in #{duration}s"
      end

      def handle_call_error(method, path, error)
        error_context = method || "UNKNOWN"
        path_context  = path   || "UNKNOWN"
        backtrace = error.backtrace.join("\n")
        logger.error("Error during SSE request handling for #{error_context} #{path_context}: #{error.message}\n#{backtrace}")
        begin
          warn "[DEBUG-SSE-Transport] #{error.class}: #{error.message}\n\t" + error.backtrace.join("\n\t")
        rescue StandardError
          nil
        end
        [500, { "Content-Type" => "text/plain", "connection" => "close" }, ["Internal Server Error"]]
      end

      # --- Public methods for Server to call (if needed, though typically handled internally) ---

      def send_notification(session_id, method, params = nil)
        message = { jsonrpc: "2.0", method: method }
        message[:params] = params if params
        enqueue_message(session_id, message)
      end

      # Broadcast a notification to all connected clients
      def broadcast_notification(method, params = nil)
        logger.debug { "Broadcasting #{method} to all clients (#{@clients.size})" }
        @clients_mutex.synchronize do
          @clients.each_key do |sid|
            send_notification(sid, method, params)
          end
        end
      end

      # --- Internal Handlers (now private) ---
      private

      def create_session
        @session = VectorMCP::Session.new(
          server_info: server.server_info,
          server_capabilities: server.server_capabilities,
          protocol_version: server.protocol_version
        )
      end

      def start_async_server
        endpoint = Falcon::Endpoint.parse("http://#{@host}:#{@port}")
        app      = self

        Async do |task|
          setup_signal_traps(task)

          logger.info("Falcon server starting on #{endpoint.url}")
          falcon_server = Falcon::Server.new(Falcon::Server.middleware(app), endpoint)
          falcon_server.run
          logger.info("Falcon server stopped.")
        ensure
          cleanup_clients
          @session = nil
          logger.info("SSE transport shut down.")
        end
      end

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

      def cleanup_clients
        @clients_mutex.synchronize do
          @clients.each_value do |conn|
            conn.queue&.close if conn.queue.respond_to?(:close)
            conn.task&.stop
          end
          @clients.clear
        end
      end

      def handle_fatal_error(error)
        logger.fatal("Fatal error starting/running SSE transport: #{error.message}\n#{error.backtrace.join("\n")}")
        exit(1)
      end

      def handle_sse_connection(env, _session)
        return invalid_method_response(env) unless get_request?(env)

        session_id   = SecureRandom.uuid
        client_queue = Async::Queue.new

        headers          = default_sse_headers
        message_post_url = build_post_url(session_id)

        logger.info("SSE client connected: #{session_id}")
        logger.debug("Sending endpoint URL: #{message_post_url}")

        client_conn, body = create_client_connection(session_id, client_queue)

        stream_client_messages(client_conn, client_queue, body, message_post_url)

        [200, headers, body]
      end

      # --- SSE helpers ---

      def request_method(env)
        env.is_a?(Hash) ? env["REQUEST_METHOD"] : env.method
      end

      def get_request?(env)
        request_method(env) == "GET"
      end

      def invalid_method_response(env)
        method = request_method(env)
        logger.warn("Received non-GET request on SSE endpoint: #{method}")
        [405, { "Content-Type" => "text/plain" }, ["Method Not Allowed"]]
      end

      def default_sse_headers
        {
          "Content-Type" => "text/event-stream",
          "Cache-Control" => "no-cache",
          "Connection" => "keep-alive",
          "X-Accel-Buffering" => "no"
        }
      end

      def build_post_url(session_id)
        "#{@path_prefix}/message?session_id=#{session_id}"
      end

      def create_client_connection(session_id, client_queue)
        client_conn = ClientConnection.new(session_id, client_queue, nil)
        body        = Async::HTTP::Body::Writable.new
        [client_conn, body]
      end

      def stream_client_messages(client_conn, queue, body, post_url)
        Async do |task|
          prepare_client_stream(client_conn, task)

          begin
            send_endpoint_event(body, post_url)
            stream_queue_messages(queue, body, client_conn)
          rescue Async::Stop, IOError, Errno::EPIPE => e
            logger.info("SSE client disconnected: #{client_conn.id} (#{e.class})")
          rescue StandardError => e
            logger.error("Error in SSE task for client #{client_conn.id}: #{e.message}\n#{e.backtrace.join("\n")}")
          ensure
            finalize_client_stream(body, queue, client_conn)
          end
        end
      end

      def prepare_client_stream(client_conn, task)
        client_conn.task = task
        @clients_mutex.synchronize { @clients[client_conn.id] = client_conn }
      end

      def send_endpoint_event(body, post_url)
        body.write("event: endpoint\ndata: #{post_url}\n\n")
      end

      def stream_queue_messages(queue, body, client_conn)
        while (message = queue.dequeue)
          json_message = message.to_json
          logger.debug { "[SSE #{client_conn.id}] Sending message: #{json_message.inspect}" }
          body.write("event: message\ndata: #{json_message}\n\n")
        end
      end

      def finalize_client_stream(body, queue, client_conn)
        body.finish
        queue.close if queue.respond_to?(:close)
        @clients_mutex.synchronize { @clients.delete(client_conn.id) }
        logger.debug("Cleaned up resources for SSE client: #{client_conn.id}")
      end

      def handle_message_post(env, session)
        return invalid_post_method_response(env) unless post_request?(env)

        raw_path   = build_raw_path(env)
        session_id = extract_session_id(raw_path)
        return error_response(nil, -32_600, "Missing session_id parameter") unless session_id

        client_conn = fetch_client_connection(session_id)
        return error_response(nil, -32_001, "Invalid session_id") unless client_conn

        request_body_str = read_request_body(env, session_id)
        return error_response(nil, -32_600, "Invalid Request: Empty body") unless request_body_str

        process_post_message(request_body_str, client_conn, session, session_id)
      end

      # --- POST helpers ---

      def post_request?(env)
        request_method(env) == "POST"
      end

      def invalid_post_method_response(env)
        method = request_method(env)
        logger.warn("Received non-POST request on message endpoint: #{method}")
        [405, { "Content-Type" => "text/plain" }, ["Method Not Allowed"]]
      end

      def build_raw_path(env)
        if env.is_a?(Hash)
          query = env["QUERY_STRING"]
          suffix = query && !query.empty? ? "?#{query}" : ""
          env["PATH_INFO"] + suffix
        else
          env.path
        end
      end

      def extract_session_id(raw_path)
        URI.decode_www_form(URI(raw_path).query || "").to_h["session_id"]
      end

      def fetch_client_connection(session_id)
        @clients_mutex.synchronize { @clients[session_id] }
      end

      def read_request_body(env, session_id)
        source = env.is_a?(Hash) ? env["rack.input"] : env.body
        body   = source&.read
        logger.error("[POST #{session_id}] Request body is empty or could not be read") unless body
        body
      end

      def process_post_message(body_str, client_conn, session, session_id)
        message = parse_json_body(body_str, session_id)
        return message if message.is_a?(Array) # Early return triplet from error

        response_data = server.handle_message(message, session, session_id)
        enqueue_formatted_response(client_conn, message["id"], response_data)
        [202, { "Content-Type" => "application/json" }, [{ status: "accepted", id: message["id"] }.to_json]]
      rescue VectorMCP::ProtocolError => e
        handle_protocol_error(e, client_conn, message)
      rescue StandardError => e
        handle_post_unexpected_error(e, client_conn, message, session_id)
      end

      def parse_json_body(body_str, session_id)
        JSON.parse(body_str)
      rescue JSON::ParserError => e
        logger.error("[POST #{session_id}] JSON Parse Error: #{e.message} for body: #{body_str.inspect}")
        id = VectorMCP::Util.extract_id_from_invalid_json(body_str)
        enqueue_error(fetch_client_connection(session_id), id, -32_700, "Parse error")
        [400, { "Content-Type" => "application/json" }, [format_error_body(id, -32_700, "Parse error")]]
      end

      def handle_protocol_error(error, client_conn, message)
        logger.error("[POST #{client_conn.id}] Protocol Error: #{error.message} (Code: #{error.code}) #{error.details.inspect}")
        request_id = error.request_id || message&.fetch("id", nil)
        enqueue_error(client_conn, request_id, error.code, error.message, error.details)

        status_code = case error.code
                      when -32_600, -32_602 then 400
                      when -32_601 then 404
                      else 500
                      end
        [status_code, { "Content-Type" => "application/json" }, [format_error_body(request_id, error.code, error.message, error.details)]]
      end

      def handle_post_unexpected_error(error, client_conn, message, session_id)
        logger.error("[POST #{session_id}] Unhandled Error: #{error.message}\n#{error.backtrace.join("\n")}")
        request_id = message&.fetch("id", nil)
        enqueue_error(client_conn, request_id, -32_603, "Internal server error", { details: error.message })
        [500, { "Content-Type" => "application/json" }, [format_error_body(request_id, -32_603, "Internal server error", { details: error.message })]]
      end

      # --- Message Enqueuing Helpers ---

      def enqueue_message(session_id, message_hash)
        client_conn = @clients_mutex.synchronize { @clients[session_id] }
        if client_conn&.queue
          logger.debug { "[ENQUEUE #{session_id}] Queuing message: #{message_hash.inspect}" }
          client_conn.queue.enqueue(message_hash)
          true
        else
          logger.warn("Cannot enqueue message: No active client queue found for session_id #{session_id}")
          false
        end
      end

      def enqueue_formatted_response(client_conn, request_id, result_data)
        response = { jsonrpc: "2.0", id: request_id, result: result_data }
        enqueue_message(client_conn.id, response)
      end

      def enqueue_error(client_conn, request_id, code, message, data = nil)
        error_payload = format_error_payload(code, message, data)
        error_msg = { jsonrpc: "2.0", id: request_id, error: error_payload }
        enqueue_message(client_conn.id, error_msg)
      end

      # --- HTTP Response Formatting Helpers ---

      def format_error_payload(code, message, data = nil)
        payload = { code:, message: }
        payload[:data] = data if data
        payload
      end

      def format_error_body(id, code, message, data = nil)
        # For the body of the HTTP error response (4xx, 5xx)
        { jsonrpc: "2.0", id:, error: format_error_payload(code, message, data) }.to_json
      end

      def error_response(id, code, message, data = nil)
        # Utility to create a full Rack error response triplet
        status = case code
                 when -32_700, -32_600, -32_602 then 400
                 when -32_601, -32_001 then 404
                 else 500
                 end
        [status, { "Content-Type" => "application/json" }, [format_error_body(id, code, message, data)]]
      end

      # Provide compatibility for older tests/specs that expect a `build_rack_app`
      # helper which returns a Rack-compatible object. Since the transport
      # itself already implements `#call`, we simply return `self`.
      def build_rack_app(session = nil)
        # In some unit tests, the session object is constructed externally and
        # passed in here. Persist it so that `#call` can forward it to
        # `handle_message_post` (ensuring mocks match expected arguments).
        @session = session if session
        self
      end
    end
  end
end
