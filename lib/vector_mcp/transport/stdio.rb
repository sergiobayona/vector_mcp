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
        # Initialize a session for this connection
        session = VectorMCP::Session.new(
          server_info: server.server_info,
          server_capabilities: server.server_capabilities,
          protocol_version: server.protocol_version
        )

        logger.info("Starting stdio transport")
        @running = true

        begin
          # Start reading from stdin in a separate thread
          @input_thread = Thread.new do
            read_input_loop(session)
          rescue StandardError => e
            logger.error("Fatal error in input thread: #{e.message}")
            logger.error(e.backtrace.join("\n"))
            exit(1) # Exit the process in case of a fatal error
          end

          # Join the input thread (wait for it to complete)
          @input_thread.join
        rescue Interrupt
          logger.info("Interrupted. Shutting down...")
        ensure
          @running = false
          @input_thread&.kill if @input_thread&.alive?
          logger.info("Stdio transport shut down")
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
        # Parse the message as JSON
        message = JSON.parse(line.strip)
        logger.debug { "Received message: #{message.inspect}" }

        # Use the server to handle the message and get a response
        response_data = server.handle_message(message, session, session_id)

        # If there's a response (i.e., it was a request, not a notification), send it
        request_id = message["id"]
        send_response(request_id, response_data) if request_id && response_data
      rescue JSON::ParserError => e
        logger.error("Failed to parse message as JSON: #{e.message}")
        id = begin
          VectorMCP::Util.extract_id_from_invalid_json(line)
        rescue StandardError
          nil
        end
        send_error(id, -32_700, "Parse error")
      rescue VectorMCP::ProtocolError => e # Catch specific protocol errors
        logger.error("Protocol error: #{e.message} (code: #{e.code})")
        logger.error("Error class: #{e.class}")
        logger.error("Error details: #{e.details.inspect}")
        request_id = begin
          e.request_id || message["id"]
        rescue StandardError
          nil
        end
        logger.error("Sending error response with code: #{e.code}")
        send_error(request_id, e.code, e.message, e.details.empty? ? nil : e.details)
      rescue StandardError => e # Catch all other errors
        logger.error("Error handling message: #{e.message}")
        logger.error(e.backtrace.join("\n"))
        request_id = begin
          message["id"]
        rescue StandardError
          nil
        end
        send_error(request_id, -32_603, "Internal error", { details: e.message })
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
