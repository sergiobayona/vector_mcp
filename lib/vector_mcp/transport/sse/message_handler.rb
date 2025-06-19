# frozen_string_literal: true

require "json"

module VectorMCP
  module Transport
    class SSE
      # Handles JSON-RPC message processing for POST requests.
      # Processes incoming messages and sends responses via SSE streams.
      class MessageHandler
        # Initializes a new message handler.
        #
        # @param server [VectorMCP::Server] The MCP server instance
        # @param session [VectorMCP::Session] The server session
        # @param logger [Logger] Logger instance for debugging
        def initialize(server, session, logger)
          @server = server
          @session = session
          @logger = logger
        end

        # Handles a POST message request from a client.
        #
        # @param env [Hash] Rack environment hash
        # @param client_conn [ClientConnection] The client connection
        # @return [Array] Rack response triplet
        def handle_post_message(env, client_conn)
          request_body = read_request_body(env)
          return error_response(nil, -32_600, "Request body is empty") if request_body.nil? || request_body.empty?

          message = parse_json_message(request_body, client_conn)
          return message if message.is_a?(Array) # Error response

          process_message(message, client_conn)
        rescue VectorMCP::ProtocolError => e
          @logger.error { "Protocol error for client #{client_conn.session_id}: #{e.message}" }
          request_id = e.request_id || message&.dig("id")
          enqueue_error_response(client_conn, request_id, e.code, e.message, e.details)
          error_response(request_id, e.code, e.message, e.details)
        rescue StandardError => e
          @logger.error { "Unexpected error for client #{client_conn.session_id}: #{e.message}\n#{e.backtrace.join("\n")}" }
          request_id = message&.dig("id")
          enqueue_error_response(client_conn, request_id, -32_603, "Internal server error")
          error_response(request_id, -32_603, "Internal server error")
        end

        private

        # Reads the request body from the Rack environment.
        #
        # @param env [Hash] Rack environment
        # @return [String, nil] Request body as string
        def read_request_body(env)
          input = env["rack.input"]
          return nil unless input

          body = input.read
          input.rewind if input.respond_to?(:rewind)
          body
        end

        # Parses JSON message from request body.
        #
        # @param body_str [String] JSON string from request body
        # @param client_conn [ClientConnection] Client connection for error handling
        # @return [Hash, Array] Parsed message or error response triplet
        def parse_json_message(body_str, client_conn)
          JSON.parse(body_str)
        rescue JSON::ParserError => e
          @logger.error { "JSON parse error for client #{client_conn.session_id}: #{e.message}" }
          malformed_id = VectorMCP::Util.extract_id_from_invalid_json(body_str)
          enqueue_error_response(client_conn, malformed_id, -32_700, "Parse error")
          error_response(malformed_id, -32_700, "Parse error")
        end

        # Processes a valid JSON-RPC message.
        #
        # @param message [Hash] Parsed JSON-RPC message
        # @param client_conn [ClientConnection] Client connection
        # @return [Array] Rack response triplet
        def process_message(message, client_conn)
          # Handle the message through the server
          response_data = @server.handle_message(message, @session, client_conn.session_id)

          # If it's a request (has id), send response via SSE
          if message["id"]
            enqueue_success_response(client_conn, message["id"], response_data)
          else
            @logger.debug { "Processed notification for client #{client_conn.session_id}" }
          end

          # Always return 202 Accepted for valid POST messages
          success_response(message["id"])
        end

        # Enqueues a successful response to the client's SSE stream.
        #
        # @param client_conn [ClientConnection] Client connection
        # @param request_id [String, Integer] Original request ID
        # @param result [Object] Response result data
        def enqueue_success_response(client_conn, request_id, result)
          response = {
            jsonrpc: "2.0",
            id: request_id,
            result: result
          }
          StreamManager.enqueue_message(client_conn, response)
        end

        # Enqueues an error response to the client's SSE stream.
        #
        # @param client_conn [ClientConnection] Client connection
        # @param request_id [String, Integer, nil] Original request ID
        # @param code [Integer] Error code
        # @param message [String] Error message
        # @param data [Object, nil] Additional error data
        def enqueue_error_response(client_conn, request_id, code, message, data = nil)
          error_payload = { code: code, message: message }
          error_payload[:data] = data if data

          error_response = {
            jsonrpc: "2.0",
            id: request_id,
            error: error_payload
          }
          StreamManager.enqueue_message(client_conn, error_response)
        end

        # Creates a successful HTTP response for the POST request.
        #
        # @param request_id [String, Integer, nil] Request ID
        # @return [Array] Rack response triplet
        def success_response(request_id)
          body = { status: "accepted", id: request_id }.to_json
          [202, { "Content-Type" => "application/json" }, [body]]
        end

        # Creates an error HTTP response for the POST request.
        #
        # @param id [String, Integer, nil] Request ID
        # @param code [Integer] Error code
        # @param message [String] Error message
        # @param data [Object, nil] Additional error data
        # @return [Array] Rack response triplet
        def error_response(id, code, message, data = nil)
          status = case code
                   when -32_700, -32_600, -32_602 then 400 # Parse, Invalid Request, Invalid Params
                   when -32_601, -32_001 then 404 # Method Not Found, Not Found
                   else 500 # Internal Error, Server Error
                   end

          error_payload = { code: code, message: message }
          error_payload[:data] = data if data

          body = {
            jsonrpc: "2.0",
            id: id,
            error: error_payload
          }.to_json

          [status, { "Content-Type" => "application/json" }, [body]]
        end
      end
    end
  end
end
