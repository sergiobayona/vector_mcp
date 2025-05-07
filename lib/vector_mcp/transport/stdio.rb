# frozen_string_literal: true

# lib/vector_mcp/transport/stdio.rb
require "json"
require_relative "../errors"
require_relative "../util"

module VectorMCP
  module Transport
    # Implements the Model Context Protocol transport over standard input/output (stdio).
    # This transport reads JSON-RPC messages line-by-line from `$stdin` and writes
    # responses/notifications line-by-line to `$stdout`.
    #
    # It is suitable for inter-process communication on the same machine where a parent
    # process spawns an MCP server and communicates with it via its stdio streams.
    class Stdio
      # @return [VectorMCP::Server] The server instance this transport is bound to.
      attr_reader :server
      # @return [Logger] The logger instance, shared with the server.
      attr_reader :logger

      # Initializes a new Stdio transport.
      #
      # @param server [VectorMCP::Server] The server instance that will handle messages.
      def initialize(server)
        @server = server
        @logger = server.logger
        @input_mutex = Mutex.new
        @output_mutex = Mutex.new
        @running = false
        @input_thread = nil
      end

      # Starts the stdio transport, listening for input and processing messages.
      # This method will block until the input stream is closed or an interrupt is received.
      #
      # @return [void]
      def run
        session = create_session
        logger.info("Starting stdio transport")
        @running = true

        begin
          launch_input_thread(session)
          @input_thread.join
        rescue Interrupt
          logger.info("Interrupted. Shutting down...")
        ensure
          shutdown_transport
        end
      end

      # Sends a JSON-RPC response message for a given request ID.
      #
      # @param id [String, Integer, nil] The ID of the request being responded to.
      # @param result [Object] The result data for the successful request.
      # @return [void]
      def send_response(id, result)
        response = {
          jsonrpc: "2.0",
          id: id,
          result: result
        }
        write_message(response)
      end

      # Sends a JSON-RPC error response message.
      #
      # @param id [String, Integer, nil] The ID of the request that caused the error.
      # @param code [Integer] The JSON-RPC error code.
      # @param message [String] A short description of the error.
      # @param data [Object, nil] Additional error data (optional).
      # @return [void]
      def send_error(id, code, message, data = nil)
        error_obj = { code: code, message: message }
        error_obj[:data] = data if data
        response = {
          jsonrpc: "2.0",
          id: id,
          error: error_obj
        }
        write_message(response)
      end

      # Sends a JSON-RPC notification message (a request without an ID).
      #
      # @param method [String] The method name of the notification.
      # @param params [Hash, Array, nil] The parameters for the notification (optional).
      # @return [void]
      def send_notification(method, params = nil)
        notification = {
          jsonrpc: "2.0",
          method: method
        }
        notification[:params] = params if params
        write_message(notification)
      end

      # Initiates an immediate shutdown of the transport.
      # Sets the running flag to false and attempts to kill the input reading thread.
      #
      # @return [void]
      def shutdown
        logger.info("Shutdown requested for stdio transport.")
        @running = false
        @input_thread&.kill if @input_thread&.alive?
      end

      private

      # The main loop for reading and processing lines from `$stdin`.
      # @api private
      # @param session [VectorMCP::Session] The session object for this connection.
      # @return [void]
      def read_input_loop(session)
        session_id = "stdio-session" # Constant identifier for stdio sessions

        while @running
          line = read_input_line
          if line.nil?
            logger.info("End of input ($stdin closed). Shutting down stdio transport.")
            break
          end
          next if line.strip.empty?

          handle_input_line(line, session, session_id)
        end
      end

      # Reads a single line from `$stdin` in a thread-safe manner.
      # @api private
      # @return [String, nil] The line read from stdin, or nil if EOF is reached.
      def read_input_line
        @input_mutex.synchronize do
          $stdin.gets
        end
      end

      # Parses a line of input as JSON and dispatches it to the server for handling.
      # Sends back any response data or errors.
      # @api private
      # @param line [String] The line of text read from stdin.
      # @param session [VectorMCP::Session] The current session.
      # @param session_id [String] The identifier for this session.
      # @return [void]
      def handle_input_line(line, session, session_id)
        message = parse_json(line)
        return if message.is_a?(Array) && message.empty? # Error handled in parse_json, indicated by empty array

        response_data = server.handle_message(message, session, session_id)
        send_response(message["id"], response_data) if message["id"] && response_data
      rescue VectorMCP::ProtocolError => e
        handle_protocol_error(e, message)
      rescue StandardError => e
        handle_unexpected_error(e, message)
      end

      # --- Run helpers (private) ---

      # Creates a new session for the stdio connection.
      # @api private
      # @return [VectorMCP::Session] The newly created session.
      def create_session
        VectorMCP::Session.new(
          server_info: server.server_info,
          server_capabilities: server.server_capabilities,
          protocol_version: server.protocol_version
        )
      end

      # Launches the input reading loop in a new thread.
      # Exits the process on fatal errors within this thread.
      # @api private
      # @param session [VectorMCP::Session] The session to pass to the input loop.
      # @return [void]
      def launch_input_thread(session)
        @input_thread = Thread.new do
          read_input_loop(session)
        rescue StandardError => e
          logger.fatal("Fatal error in stdio input thread: #{e.message}\n#{e.backtrace.join("\n")}")
          exit(1) # Critical failure, exit the server process
        end
      end

      # Cleans up transport resources, ensuring the input thread is stopped.
      # @api private
      # @return [void]
      def shutdown_transport
        @running = false
        @input_thread&.kill if @input_thread&.alive?
        logger.info("Stdio transport shut down gracefully.")
      end

      # --- Input helpers (private) ---

      # Parses a line of text as JSON.
      # If parsing fails, sends a JSON-RPC ParseError and returns an empty array
      # to signal that the error has been handled.
      # @api private
      # @param line [String] The line to parse.
      # @return [Hash, Array] The parsed JSON message as a Hash, or an empty Array if a parse error occurred and was handled.
      def parse_json(line)
        JSON.parse(line.strip)
      rescue JSON::ParserError => e
        logger.error("Failed to parse message as JSON: #{line.strip.inspect} - #{e.message}")
        id = begin
          VectorMCP::Util.extract_id_from_invalid_json(line)
        rescue StandardError
          nil # Best effort, don't let ID extraction fail fatally
        end
        send_error(id, -32_700, "Parse error")
        [] # Signal that error was handled
      end

      # Handles known VectorMCP::ProtocolError exceptions during message processing.
      # @api private
      # @param error [VectorMCP::ProtocolError] The protocol error instance.
      # @param message [Hash, nil] The original parsed message, if available.
      # @return [void]
      def handle_protocol_error(error, message)
        logger.error("Protocol error processing message: #{error.message} (code: #{error.code}), Details: #{error.details.inspect}")
        request_id = error.request_id || message&.fetch("id", nil)
        send_error(request_id, error.code, error.message, error.details)
      end

      # Handles unexpected StandardError exceptions during message processing.
      # @api private
      # @param error [StandardError] The unexpected error instance.
      # @param message [Hash, nil] The original parsed message, if available.
      # @return [void]
      def handle_unexpected_error(error, message)
        logger.error("Unexpected error handling message: #{error.message}\n#{error.backtrace.join("\n")}")
        request_id = message&.fetch("id", nil)
        send_error(request_id, -32_603, "Internal error", { details: error.message })
      end

      # Writes a message hash to `$stdout` as a JSON string, followed by a newline.
      # Ensures the output is flushed. Handles EPIPE errors if stdout closes.
      # @api private
      # @param message [Hash] The message hash to send.
      # @return [void]
      def write_message(message)
        json_msg = message.to_json
        logger.debug { "Sending stdio message: #{json_msg}" }

        begin
          @output_mutex.synchronize do
            $stdout.puts(json_msg)
            $stdout.flush
          end
        rescue Errno::EPIPE
          logger.error("Output pipe ($stdout) closed. Cannot send message. Shutting down stdio transport.")
          shutdown # Initiate shutdown as we can no longer communicate
        end
      end
    end
  end
end
