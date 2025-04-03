# frozen_string_literal: true

require "json"
require "rack"
require "thin"
require "faye/websocket"
require "eventmachine"
require_relative "../errors"
require_relative "../util"

module MCPRuby
  module Transport
    # Server-Sent Events (SSE) transport for MCP
    class SSE
      attr_reader :logger, :server

      def initialize(server, options = {})
        @server = server
        @logger = server.logger
        @host = options[:host] || "localhost"
        @port = options[:port] || 3000
        @path_prefix = options[:path_prefix] || "/mcp"
        @clients = {}
        @message_queue = {}
      end

      def run
        logger.info("Starting server with SSE transport on #{@host}:#{@port}")
        session = MCPRuby::Session.new(
          server_info: server.server_info,
          server_capabilities: server.server_capabilities,
          protocol_version: server.protocol_version
        )

        begin
          app = build_rack_app(session)
          start_server(app)
        rescue StandardError => e
          logger.fatal("Fatal error in SSE transport: #{e.message}\n#{e.backtrace.join("\n")}")
          exit(1)
        end
      end

      def send_response(id, result)
        send_message(jsonrpc: "2.0", id: id, result: result)
      end

      private

      def build_rack_app(session)
        # Build a Rack application that handles HTTP requests
        Rack::Builder.new do
          use Rack::CommonLogger

          map "/mcp/sse" do
            # Handler for SSE endpoint
            run lambda { |env|
              # Save the connection for sending SSE events
              client_id = env["HTTP_CLIENT_ID"] || SecureRandom.uuid
              response_headers = {
                "Content-Type" => "text/event-stream",
                "Cache-Control" => "no-cache",
                "Connection" => "keep-alive"
              }

              [200, response_headers, SSEStream.new(client_id, self)]
            }
          end

          map "/mcp/message" do
            # Handler for receiving JSON-RPC messages
            run lambda { |env|
              # Parse the JSON-RPC message from the request
              request = Rack::Request.new(env)
              client_id = request.env["HTTP_CLIENT_ID"] || "default"

              if request.post?
                begin
                  body = request.body.read
                  message = JSON.parse(body)

                  # Process the message
                  result = handle_message(message, session, client_id)
                  [200, { "Content-Type" => "application/json" }, [result.to_json]]
                rescue JSON::ParserError => e
                  logger.error("JSON Parse Error: #{e.message}")
                  error_response = {
                    jsonrpc: "2.0",
                    error: {
                      code: -32_700,
                      message: "Parse error"
                    }
                  }
                  [400, { "Content-Type" => "application/json" }, [error_response.to_json]]
                rescue StandardError => e
                  logger.error("Error processing message: #{e.message}")
                  error_response = {
                    jsonrpc: "2.0",
                    error: {
                      code: -32_603,
                      message: "Internal server error",
                      data: { details: e.message }
                    }
                  }
                  [500, { "Content-Type" => "application/json" }, [error_response.to_json]]
                end
              else
                [405, { "Content-Type" => "text/plain" }, ["Method not allowed"]]
              end
            }
          end
        end
      end

      def start_server(app)
        thin_options = {
          app: app,
          Host: @host,
          Port: @port,
          signals: false
        }

        # Start the server in the EventMachine loop
        EventMachine.run do
          # Thin server to handle HTTP requests
          Thin::Server.start(thin_options[:Host], thin_options[:Port], app)

          # Handle SIGINT and SIGTERM for graceful shutdown
          trap("INT") { stop_server }
          trap("TERM") { stop_server }

          logger.info("SSE transport started at http://#{@host}:#{@port}#{@path_prefix}")
        end
      end

      def stop_server
        logger.info("Stopping SSE transport...")
        # Close all client connections
        @clients.each_value(&:close)
        # Stop the EventMachine loop
        EventMachine.stop
      end

      def handle_message(message, session, client_id)
        # Register client if not already registered
        unless @clients[client_id]
          logger.info("New client connection: #{client_id}")
          @clients[client_id] = { id: client_id, messages: [] }
        end

        # Process the message
        begin
          response = server.handle_message(message, session, self)
          # Queue the response for SSE delivery
          @message_queue[client_id] ||= []
          @message_queue[client_id] << response if response

          { status: "success" }
        rescue MCPRuby::ProtocolError => e
          logger.error("Protocol Error: #{e.message} (Code: #{e.code})")
          {
            jsonrpc: "2.0",
            id: message["id"],
            error: {
              code: e.code,
              message: e.message,
              data: e.details
            }
          }
        rescue StandardError => e
          logger.error("Unhandled error processing message: #{e.message}\n#{e.backtrace.join("\n")}")
          {
            jsonrpc: "2.0",
            id: message["id"],
            error: {
              code: -32_603,
              message: "Internal server error",
              data: { details: e.message }
            }
          }
        end
      end

      def send_message(message_hash)
        logger.debug { "Sending message: #{message_hash.inspect}" }

        # Send to all connected clients
        @clients.each do |client_id, client|
          event_data = "data: #{message_hash.to_json}\n\n"
          client.write(event_data)
        rescue StandardError => e
          logger.error("Error sending to client #{client_id}: #{e.message}")
          @clients.delete(client_id) # Remove disconnected client
        end
      end

      def send_notification(method, params = nil)
        message = { jsonrpc: "2.0", method: method }
        message[:params] = params if params
        send_message(**message)
      end

      def send_error(id, code, message, data)
        error_obj = { code: code, message: message }
        error_obj[:data] = data if data
        send_message(jsonrpc: "2.0", id: id, error: error_obj)
      end

      # SSE Stream class to handle the event stream
      class SSEStream
        def initialize(client_id, transport)
          @client_id = client_id
          @transport = transport
          @closed = false
        end

        def each
          # Send headers
          yield "retry: 10000\n\n"

          # Register this client
          @transport.instance_variable_get(:@clients)[@client_id] = self

          # Keep the connection open
          loop do
            break if @closed

            # Send a keep-alive comment every 15 seconds
            yield ": keep-alive\n\n"
            sleep 15
          end
        end

        def write(data)
          # Method called by transport to send data
          yield data if respond_to?(:each) && !@closed
        end

        def close
          @closed = true
        end
      end
    end
  end
end
