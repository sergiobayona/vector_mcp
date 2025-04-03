# frozen_string_literal: true

require "json"
require "securerandom"
require "async"
require "async/http/endpoint"
require "async/http/body/writable"
require "falcon/server"
require "falcon/endpoint"
require "rack/builder"
require "rack/static"
require "rack/common_logger"
require "rack/lint"

require_relative "../errors"
require_relative "../util"
require_relative "../session" # Make sure session is loaded

module MCPRuby
  module Transport
    # Server-Sent Events (SSE) transport for MCP using the 'async' ecosystem.
    class SSE
      attr_reader :logger, :server, :host, :port, :path_prefix

      # Internal structure to hold client connection state
      ClientConnection = Struct.new(:id, :queue, :task)

      def initialize(server, options = {})
        @server = server
        @logger = server.logger
        @host = options[:host] || "localhost"
        @port = options[:port] || 3000
        # Ensure path_prefix starts with / and doesn't end with /
        prefix = options[:path_prefix] || "/mcp"
        @path_prefix = prefix.start_with?("/") ? prefix : "/#{prefix}"
        @path_prefix = @path_prefix.delete_suffix("/")

        # Thread-safe storage for client connections (maps session_id -> ClientConnection)
        @clients = {}
        @clients_mutex = Mutex.new
        logger.debug { "SSE Transport initialized with prefix: #{@path_prefix}" }
      end

      def run
        logger.info("Starting server with async SSE transport on #{@host}:#{@port}")

        # Initialize a shared session object (could be per-connection if needed)
        session = MCPRuby::Session.new(
          server_info: server.server_info,
          server_capabilities: server.server_capabilities,
          protocol_version: server.protocol_version
        )

        app = build_rack_app(session)
        endpoint = Falcon::Endpoint.parse("http://#{@host}:#{@port}")

        Async do |task|
          # Set up signal handling within the Async block
          task.reactor.trap(:INT) do
            logger.info "SIGINT received, stopping server..."
            task.stop
          end
          task.reactor.trap(:TERM) do
            logger.info "SIGTERM received, stopping server..."
            task.stop
          end

          logger.info("Falcon server starting on #{endpoint.url}")
          server = Falcon::Server.new(Falcon::Server.middleware(app), endpoint)
          server.run
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
          logger.info("SSE transport shut down.")
        end
      rescue StandardError => e
        logger.fatal("Fatal error starting/running SSE transport: #{e.message}\n#{e.backtrace.join("\n")}")
        exit(1)
      end

      # --- Public methods for Server to call (if needed, though typically handled internally) ---

      def send_notification(session_id, method, params = nil)
        message = { jsonrpc: "2.0", method: method }
        message[:params] = params if params
        enqueue_message(session_id, message)
      end

      private

      # --- Rack App Construction ---

      def build_rack_app(session)
        sse_path = "#{@path_prefix}/sse"
        message_path = "#{@path_prefix}/message"
        logger.info("Building Rack app with SSE endpoint: #{sse_path}, Message endpoint: #{message_path}")

        this = self # Capture self for closure

        Rack::Builder.new do
          use Rack::CommonLogger, this.logger # Log requests using our logger
          use Rack::Lint # Helps catch Rack specification violations

          map sse_path do
            run ->(env) { this.handle_sse_connection(env, session) }
          end

          map message_path do
            run ->(env) { this.handle_message_post(env, session) }
          end

          # Optional: Add a root path handler for basic info/health check
          map "/" do
            run ->(_env) { [200, { "Content-Type" => "text/plain" }, ["MCPRuby Server OK"]] }
          end
        end.to_app
      end

      # --- SSE Connection Handler (GET /mcp/sse) ---

      def handle_sse_connection(env, session)
        request = Rack::Request.new(env)
        unless request.get?
          logger.warn("Received non-GET request on SSE endpoint: #{request.request_method}")
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

        # Store client connection info
        # The task is captured within the Async::HTTP::Body::Writable block below
        client_conn = ClientConnection.new(session_id, client_queue, nil)
        @clients_mutex.synchronize { @clients[session_id] = client_conn }

        # Use Async::HTTP::Body::Writable for the response body
        body = Async::HTTP::Body::Writable.new

        # Run the SSE event sending logic in a separate task
        # Capture the task so we can potentially stop it later
        sse_task = Async do |task|
          client_conn.task = task # Store the task reference
          begin
            # 1. Send the initial endpoint event
            body.write("event: endpoint\ndata: #{message_post_url}\n\n")

            # 2. Start sending keep-alive comments periodically
            keep_alive_task = task.async do
              loop do
                task.sleep(15) # Send keep-alive every 15 seconds
                body.write(": keep-alive\n\n")
              rescue Async::Stop, IOError, Errno::EPIPE
                break # Stop if the main task stops or connection breaks
              end
            end

            # 3. Listen on the client's queue and send messages
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
            keep_alive_task&.stop # Stop the keep-alive timer
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

      # --- Message POST Handler (POST /mcp/message?session_id=...) ---

      def handle_message_post(env, session)
        request = Rack::Request.new(env)

        unless request.post?
          logger.warn("Received non-POST request on message endpoint: #{request.request_method}")
          return [405, { "Content-Type" => "text/plain" }, ["Method Not Allowed"]]
        end

        session_id = request.params["session_id"]
        unless session_id && !session_id.empty?
          logger.error("Missing session_id query parameter")
          return error_response(nil, -32_600, "Missing session_id parameter")
        end

        client_conn = @clients_mutex.synchronize { @clients[session_id] }
        unless client_conn
          logger.error("Invalid or expired session_id: #{session_id}")
          return error_response(nil, -32_001, "Invalid session_id") # Use a custom server error
        end

        begin
          body = request.body.read
          message = JSON.parse(body)
          logger.debug { "[POST #{session_id}] Received raw message: #{body.inspect}" }

          # Let the server process the message. It should return the response data hash or raise an error.
          response_data = server.handle_message(message, session, session_id) # Pass session_id for context

          # Enqueue the formatted response/error to be sent over SSE
          enqueue_formatted_response(client_conn, message["id"], response_data)

          # Immediately return 202 Accepted to the POST request
          [202, { "Content-Type" => "application/json" }, [{ status: "accepted", id: message["id"] }.to_json]]
        rescue JSON::ParserError => e
          logger.error("[POST #{session_id}] JSON Parse Error: #{e.message}")
          # Attempt to find ID for error response, enqueue if possible
          id = MCPRuby::Util.extract_id_from_invalid_json(body)
          enqueue_error(client_conn, id, -32_700, "Parse error")
          # Return 400 Bad Request to the POST
          [400, { "Content-Type" => "application/json" }, [format_error_body(id, -32_700, "Parse error")]]
        rescue MCPRuby::ProtocolError => e
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
        if client_conn && client_conn.queue && !client_conn.queue.closed?
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
    end # class SSE
  end # module Transport
end # module MCPRuby
