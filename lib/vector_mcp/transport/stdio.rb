# frozen_string_literal: true

# lib/vector_mcp/transport/stdio.rb
require "json"
require_relative "../errors"
require_relative "../util"

module VectorMCP
  module Transport
    # Simple stdio transport for MCP
    class Stdio
      attr_reader :server, :logger

      def initialize(server)
        @server = server
        @logger = server.logger
        @input_mutex = Mutex.new
        @output_mutex = Mutex.new
        @running = false
        @input_thread = nil
      end

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

      # Send a JSON-RPC response with result data
      def send_response(id, result)
        response = {
          jsonrpc: "2.0",
          id: id,
          result: result
        }

        write_message(response)
      end

      # Send a JSON-RPC error response
      def send_error(id, code, message, data = nil)
        error = { code: code, message: message }
        error[:data] = data if data

        response = {
          jsonrpc: "2.0",
          id: id,
          error: error
        }

        write_message(response)
      end

      # Send a notification (one-way message from server to client)
      def send_notification(method, params = nil)
        notification = {
          jsonrpc: "2.0",
          method: method
        }
        notification[:params] = params if params

        write_message(notification)
      end

      # Immediate shutdown of the transport
      def shutdown
        @running = false
        @input_thread&.kill if @input_thread&.alive?
      end

      private

      # Main input reading loop
      def read_input_loop(session)
        session_id = "stdio-session" # A simple constant identifier for stdio sessions

        while @running
          # Read a line from stdin
          line = read_input_line

          # Handle the EOF condition (stdin closed)
          if line.nil?
            logger.info("End of input. Shutting down.")
            break
          end

          # Skip empty lines
          next if line.strip.empty?

          handle_input_line(line, session, session_id)
        end
      end

      # Read a single line from stdin with locking
      def read_input_line
        @input_mutex.synchronize do
          $stdin.gets
        end
      end

      # Process a single input line as a JSON-RPC message
      def handle_input_line(line, session, session_id)
        message = parse_json(line)
        return if message.is_a?(Array) # Already handled error triplet

        response_data = server.handle_message(message, session, session_id)
        send_response(message["id"], response_data) if message["id"] && response_data
      rescue VectorMCP::ProtocolError => e
        handle_protocol_error(e, message)
      rescue StandardError => e
        handle_unexpected_error(e, message)
      end

      # --- Run helpers ---

      def create_session
        VectorMCP::Session.new(
          server_info: server.server_info,
          server_capabilities: server.server_capabilities,
          protocol_version: server.protocol_version
        )
      end

      def launch_input_thread(session)
        @input_thread = Thread.new do
          read_input_loop(session)
        rescue StandardError => e
          logger.error("Fatal error in input thread: #{e.message}")
          logger.error(e.backtrace.join("\n"))
          exit(1)
        end
      end

      def shutdown_transport
        @running = false
        @input_thread&.kill if @input_thread&.alive?
        logger.info("Stdio transport shut down")
      end

      # --- Input helpers ---

      def parse_json(line)
        JSON.parse(line.strip)
      rescue JSON::ParserError => e
        logger.error("Failed to parse message as JSON: #{e.message}")
        id = begin
          VectorMCP::Util.extract_id_from_invalid_json(line)
        rescue StandardError
          nil
        end
        send_error(id, -32_700, "Parse error")
        []
      end

      def handle_protocol_error(error, message)
        logger.error("Protocol error: #{error.message} (code: #{error.code})")
        logger.error("Error details: #{error.details.inspect}")
        request_id = error.request_id || message&.fetch("id", nil)
        send_error(request_id, error.code, error.message, error.details)
      end

      def handle_unexpected_error(error, message)
        logger.error("Error handling message: #{error.message}")
        logger.error(error.backtrace.join("\n"))
        request_id = message&.fetch("id", nil)
        send_error(request_id, -32_603, "Internal error", { details: error.message })
      end

      # Write a message to stdout with locking
      def write_message(message)
        json_msg = message.to_json
        logger.debug { "Sending message: #{json_msg}" }

        begin
          @output_mutex.synchronize do
            $stdout.puts(json_msg)
            $stdout.flush # Ensure the message is sent immediately
          end
        rescue Errno::EPIPE
          logger.error("Output pipe closed. Shutting down.")
          @running = false
        end
      end
    end
  end
end
