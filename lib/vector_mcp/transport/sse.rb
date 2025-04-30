# frozen_string_literal: true

require "json"
require "securerandom"
require "async"
require "async/http/endpoint"
require "async/http/body/writable"
require "protocol/http/response"
require "protocol/http/headers"
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

        # Initialize a shared session object for this run
        @session = VectorMCP::Session.new(
          server_info: server.server_info,
          server_capabilities: server.server_capabilities,
          protocol_version: server.protocol_version
        )

        # The transport instance itself acts as the app
        app = self
        endpoint = Falcon::Endpoint.parse("http://#{@host}:#{@port}")

        Async do |task|
          # Set up signal handling using Async's signal handling
          task.async do
            Async::IO::Signal.trap(:INT) do
              logger.info "SIGINT received, stopping server..."
              task.stop
            end
            Async::IO::Signal.trap(:TERM) do
              logger.info "SIGTERM received, stopping server..."
              task.stop
            end
          end

          logger.info("Falcon server starting on #{endpoint.url}")
          # Pass the transport instance (self) wrapped in standard middleware
          falcon_server = Falcon::Server.new(Falcon::Server.middleware(app), endpoint)
          falcon_server.run
          logger.info("Falcon server stopped.")
        ensure
          # Cleanup: Close all client queues when the server stops
          @clients_mutex.synchronize do
            @clients.each_value do |conn|
              conn.queue&.close
              conn.task&.stop # Attempt to stop the client's SSE task
            end
            @clients.clear
          end
          @session = nil # Clear session
          logger.info("SSE transport shut down.")
        end
      rescue StandardError => e
        logger.fatal("Fatal error starting/running SSE transport: #{e.message}\n#{e.backtrace.join("\n")}")
        exit(1)
      end

      # --- Rack-compatible call method --- #

      def call(env)
        start_time = Time.now
        # env here is typically Async::HTTP::Protocol::HTTP1::Request
        path = env.path
        method = env.method

        logger.info "Received #{method} request for #{path}"

        status, headers_hash, body =
          case path
          when @sse_path
            handle_sse_connection(env, @session)
          when @message_path
            handle_message_post(env, @session)
          when "/"
            # Simple root/health check
            [200, { "Content-Type" => "text/plain" }, ["VectorMCP Server OK"]]
          else
            [404, { "Content-Type" => "text/plain" }, ["Not Found"]]
          end

        # Simple logging similar to CommonLogger
        duration = format("%.4f", Time.now - start_time)
        logger.info "Responded #{status} to #{method} #{path} in #{duration}s"

        # Return a Protocol::HTTP::Response object with Protocol::HTTP::Headers
        Protocol::HTTP::Response.new(status, Protocol::HTTP::Headers.new(headers_hash), body)
      rescue StandardError => e
        # Generic error handler for unexpected issues in routing/handling
        logger.error("Error during SSE request handling for #{method} #{path}: #{e.message}\n#{e.backtrace.join("\n")}")
        # Return a 500 Protocol::HTTP::Response object
        Protocol::HTTP::Response.new(
          500,
          Protocol::HTTP::Headers.new({ "Content-Type" => "text/plain", "connection" => "close" }),
          ["Internal Server Error"]
        )
      end

      # --- Public methods for Server to call (if needed, though typically handled internally) ---

      def send_notification(session_id, method, params = nil)
        message = { jsonrpc: "2.0", method: method }
        message[:params] = params if params
        enqueue_message(session_id, message)
      end

      # --- Internal Handlers (now private) ---
      private

      def handle_sse_connection(env, _session)
        # env is Async::HTTP::Request, but Rack::Request can wrap it
        # However, to avoid potential issues, let's access properties directly if possible
        unless env.method == "GET"
          logger.warn("Received non-GET request on SSE endpoint: #{env.method}")
          return [405, { "Content-Type" => "text/plain" }, ["Method Not Allowed"]]
        end

        session_id = SecureRandom.uuid
        client_queue = Async::Queue.new

        headers = {
          "Content-Type" => "text/event-stream",
          "Cache-Control" => "no-cache",
          "Connection" => "keep-alive",
          "X-Accel-Buffering" => "no" # Useful for nginx proxying
        }

        # Create the unique URL for the client to POST messages back to
        message_post_url = "#{@path_prefix}/message?session_id=#{session_id}"

        logger.info("SSE client connected: #{session_id}")
        logger.debug("Sending endpoint URL: #{message_post_url}")

        # Create a ClientConnection object but don't register it yet
        client_conn = ClientConnection.new(session_id, client_queue, nil)

        # Use Async::HTTP::Body::Writable for the response body
        body = Async::HTTP::Body::Writable.new

        # Create and launch the client task directly with a variable to hold the reference
        client_task = Async do |task|
          # Set the task reference immediately
          client_conn.task = task

          # NOW register the client with complete information
          @clients_mutex.synchronize { @clients[session_id] = client_conn }

          begin
            # 1. Send the initial endpoint event
            body.write("event: endpoint\ndata: #{message_post_url}\n\n")

            # 2. Listen on the client's queue and send messages
            while (message = client_queue.dequeue)
              json_message = message.to_json # Expecting fully formed JSON-RPC hash
              logger.debug { "[SSE #{session_id}] Sending message: #{json_message.inspect}" }
              body.write("event: message\ndata: #{json_message}\n\n")
            end
          rescue Async::Stop, IOError, Errno::EPIPE => e
            logger.info("SSE client disconnected: #{session_id} (#{e.class})")
          rescue StandardError => e
            logger.error("Error in SSE task for client #{session_id}: #{e.message}\n#{e.backtrace.join("\n")}")
          ensure
            body.finish # Signal end of stream to Falcon
            client_queue.close # Close the queue
            # Remove client connection info
            @clients_mutex.synchronize { @clients.delete(session_id) }
            logger.debug("Cleaned up resources for SSE client: #{session_id}")
          end
        end

        # Return the Rack response triplet
        [200, headers, body]
      end

      def handle_message_post(env, session)
        unless env.method == "POST"
          logger.warn("Received non-POST request on message endpoint: #{env.method}")
          return [405, { "Content-Type" => "text/plain" }, ["Method Not Allowed"]]
        end

        # Extract query parameters - Async::HTTP::Request doesn't have `params` like Rack::Request
        # We need to parse the query string from the path/target
        query_params = URI.decode_www_form(URI(env.path).query || "").to_h
        session_id = query_params["session_id"]

        unless session_id && !session_id.empty?
          logger.error("Missing session_id query parameter in path: #{env.path}")
          return error_response(nil, -32_600, "Missing session_id parameter")
        end

        client_conn = @clients_mutex.synchronize { @clients[session_id] }
        unless client_conn
          logger.error("Invalid or expired session_id: #{session_id}")
          return error_response(nil, -32_001, "Invalid session_id") # Use a custom server error
        end

        begin
          # Read the body - Async::HTTP::Request body might need explicit reading
          request_body_str = env.body&.read
          unless request_body_str
            logger.error("[POST #{session_id}] Request body is empty or could not be read")
            return error_response(nil, -32_600, "Invalid Request: Empty body")
          end

          message = JSON.parse(request_body_str)
          logger.debug { "[POST #{session_id}] Received raw message: #{request_body_str.inspect}" }

          # Let the server process the message. It should return the response data hash or raise an error.
          response_data = server.handle_message(message, session, session_id) # Pass session_id for context

          # Enqueue the formatted response/error to be sent over SSE
          enqueue_formatted_response(client_conn, message["id"], response_data)

          # Immediately return 202 Accepted to the POST request
          [202, { "Content-Type" => "application/json" }, [{ status: "accepted", id: message["id"] }.to_json]]
        rescue JSON::ParserError => e
          logger.error("[POST #{session_id}] JSON Parse Error: #{e.message} for body: #{request_body_str.inspect}")
          # Attempt to find ID for error response, enqueue if possible
          id = VectorMCP::Util.extract_id_from_invalid_json(request_body_str)
          enqueue_error(client_conn, id, -32_700, "Parse error")
          # Return 400 Bad Request to the POST
          [400, { "Content-Type" => "application/json" }, [format_error_body(id, -32_700, "Parse error")]]
        rescue VectorMCP::ProtocolError => e
          logger.error("[POST #{session_id}] Protocol Error: #{e.message} (Code: #{e.code}) #{e.details.inspect}")
          request_id = e.request_id || message&.fetch("id", nil)
          enqueue_error(client_conn, request_id, e.code, e.message, e.details)
          # Return appropriate status code based on error type
          status_code = case e.code
                        when -32_600, -32_602 then 400 # Bad Request for Invalid Request/Params
                        when -32_601 then 404 # Not Found for Method Not Found
                        else 500 # Internal Server Error for others
                        end
          [status_code, { "Content-Type" => "application/json" }, [format_error_body(request_id, e.code, e.message, e.details)]]
        rescue StandardError => e
          logger.error("[POST #{session_id}] Unhandled Error: #{e.message}\n#{e.backtrace.join("\n")}")
          request_id = message&.fetch("id", nil)
          enqueue_error(client_conn, request_id, -32_603, "Internal server error", { details: e.message })
          [500, { "Content-Type" => "application/json" }, [format_error_body(request_id, -32_603, "Internal server error", { details: e.message })]]
        end
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
                 when -32_601 then 404
                 when -32_001 then 404 # NotFoundError
                 else 500
                 end
        [status, { "Content-Type" => "application/json" }, [format_error_body(id, code, message, data)]]
      end
    end
  end
end
