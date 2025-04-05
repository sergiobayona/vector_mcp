# frozen_string_literal: true

# lib/mcp_ruby/transport/stdio.rb
require "json"
require "strscan"
require_relative "../errors"
require_relative "../util"

module MCPRuby
  module Transport
    class Stdio
      attr_reader :logger, :server

      # Maximum buffer size to prevent memory exhaustion
      MAX_BUFFER_SIZE = 1024 * 1024 # 1MB

      def initialize(server)
        @server = server
        @logger = server.logger # Use the server's logger instance
        @buffer = String.new("") # Create a mutable string
        @json_depth = 0
        @in_string = false
        @escape_next = false
      end

      def run
        logger.info("Starting server with stdio transport")
        session = MCPRuby::Session.new(
          server_info: server.server_info,
          server_capabilities: server.server_capabilities,
          protocol_version: server.protocol_version
        )

        begin
          # Main processing loop
          while chunk = read_chunk
            # Check buffer size limits
            if (@buffer.length + chunk.length) > MAX_BUFFER_SIZE
              logger.error("Input buffer exceeded maximum size (#{MAX_BUFFER_SIZE} bytes)")
              send_error(nil, -32_700, "JSON message too large", nil)
              @buffer = String.new("") # Reset buffer with a mutable string
              next
            end

            # Add new data to buffer
            @buffer << chunk

            # Process complete messages
            process_messages(session)
          end

          logger.info("Stdin closed, shutting down.")
        rescue Interrupt
          logger.info("Interrupt received, shutting down gracefully.")
        rescue IOError, Errno::EBADF => e
          logger.info("IO closed: #{e.message}")
        rescue StandardError => e
          logger.fatal("Fatal error in stdio transport loop: #{e.message}\n#{e.backtrace.join("\n")}")
          raise e
        end
      end

      def send_response(id, result)
        send_message({ jsonrpc: "2.0", id: id, result: result })
      end

      private

      # Read a chunk of data from stdin
      # This method is separated to make testing easier
      def read_chunk
        # For tests - use gets if it's a StringIO (no nonblock support)
        if $stdin.is_a?(StringIO)
          line = $stdin.gets
          return line unless line.nil?

          return nil # EOF
        end

        # For real operation - use read_nonblock with exception: false
        # This returns nil on EOF, data on success, and :wait_readable if would block
        begin
          chunk = $stdin.read_nonblock(4096, exception: false)

          # Handle the three possible return values
          if chunk.nil? # EOF
            nil
          elsif chunk == :wait_readable # Would block
            # Wait a tiny bit to avoid cpu spinning
            sleep 0.01
            "" # Return empty string to continue loop
          else
            chunk # Normal case - return data
          end
        rescue IO::WaitReadable
          # Alternative for Ruby versions that don't support exception: false
          sleep 0.01
          ""
        end
      end

      def process_buffer(session)
        process_messages(session)
      end

      def process_messages(session)
        # Process as many complete messages as we can find
        while (message_end = find_message_end)
          message = @buffer[0..message_end].strip
          @buffer = String.new(@buffer[(message_end + 1)..-1] || "")

          begin
            JSON.parse(message) # Validate JSON
            handle_json_message(message, session)
          rescue JSON::ParserError => e
            logger.error("JSON Parse Error: #{e.message}")
            # Try to extract ID from the partial JSON
            if (id_match = message.match(/"id"\s*:\s*"?([^,"}\s]+)"?/i))
              id = id_match[1]
              send_error(id, -32_700, "Parse error", nil)
            end
          end
        end

        # If we have a newline but couldn't parse any messages, try to handle as error
        return unless @buffer.include?("\n") && !@buffer.strip.empty?

        begin
          JSON.parse(@buffer)
        rescue JSON::ParserError => e
          logger.error("JSON Parse Error: #{e.message}")
          if (id_match = @buffer.match(/"id"\s*:\s*"?([^,"}\s]+)"?/i))
            id = id_match[1]
            send_error(id, -32_700, "Parse error", nil)
          end
          @buffer = String.new("")
        end
      end

      def find_message_end
        depth = 0
        in_string = false
        escape_next = false

        @buffer.each_char.with_index do |char, i|
          if escape_next
            escape_next = false
            next
          end

          case char
          when '"'
            in_string = !in_string
          when "\\"
            escape_next = true if in_string
          when "{"
            depth += 1 unless in_string
          when "}"
            depth -= 1 unless in_string
            return i if depth == 0 && depth >= 0
          when "\n"
            # If we hit a newline and we're not in the middle of a JSON object,
            # treat everything up to here as a potential message
            return i if depth == 0
          end
        end
        nil
      end

      def handle_json_message(json_str, session)
        logger.debug { "Processing JSON message: #{json_str.inspect}" }
        message = nil
        begin
          message = JSON.parse(json_str)
          result = server.handle_message(message, session, self)
          # Send the result if it's not nil (notifications return nil)
          send_message({ jsonrpc: "2.0", id: message["id"], result: result }) if result
        rescue JSON::ParserError => e
          logger.error("JSON Parse Error: #{e.message}")
          # Extract ID from invalid JSON using a simple regex
          id = json_str.match(/"id"\s*:\s*"?([^,"}\s]+)"?/i)&.captures&.first
          send_error(id, -32_700, "Parse error", nil)
        rescue MCPRuby::ProtocolError => e # Catch specific protocol errors
          logger.error("Protocol Error: #{e.message} (Code: #{e.code})")
          send_error(e.request_id || message&.fetch("id", nil), e.code, e.message, e.details)
        rescue StandardError => e
          logger.error("Unhandled error processing message: #{e.message}\n#{e.backtrace.join("\n")}")
          id = message&.fetch("id", nil)
          send_error(id, -32_603, "Internal server error", { details: e.message }) if id
        end
      end

      # --- JSON-RPC Formatting Methods (now part of transport) ---

      def send_message(message_hash)
        # Ensure message_hash doesn't contain nil values which JSON ignores
        # compact_hash = message_hash.compact # Be careful, this removes legitimate nulls too!
        # Best practice: Ensure upstream handlers return intended JSON structures.
        json_message = message_hash.to_json
        logger.debug { "Sending raw: #{json_message.inspect}" }
        $stdout.puts(json_message)
        $stdout.flush # Ensure message is sent immediately
      rescue StandardError => e
        # Log errors during sending, but avoid crashing the loop if possible
        logger.error("Failed to send message: #{e.message}")
      end

      def send_error(id, code, message, data)
        # id can be null for certain errors (parse error before ID known)
        error_obj = { code: code, message: message }
        error_obj[:data] = data if data
        send_message({ jsonrpc: "2.0", id: id, error: error_obj })
      end

      def send_notification(method, params = nil)
        message = { jsonrpc: "2.0", method: method }
        message[:params] = params if params
        send_message(message)
      end
    end
  end
end
