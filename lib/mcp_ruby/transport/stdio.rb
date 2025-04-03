# frozen_string_literal: true

# lib/mcp_ruby/transport/stdio.rb
require "json"
require_relative "../errors"
require_relative "../util"

module MCPRuby
  module Transport
    class Stdio
      attr_reader :logger, :server

      def initialize(server)
        @server = server
        @logger = server.logger # Use the server's logger instance
      end

      def run
        logger.info("Starting server with stdio transport")
        session = MCPRuby::Session.new(
          server_info: server.server_info,
          server_capabilities: server.server_capabilities,
          protocol_version: server.protocol_version
        )

        loop do
          line = $stdin.gets
          break unless line # EOF

          line.strip!
          next if line.empty?

          logger.debug { "Received raw: #{line.inspect}" } # Use block for lazy evaluation
          handle_line(line, session)
        end
        logger.info("Stdin closed, shutting down.")
      rescue Interrupt
        logger.info("Interrupt received, shutting down gracefully.")
      rescue StandardError => e
        logger.fatal("Fatal error in stdio transport loop: #{e.message}\n#{e.backtrace.join("\n")}")
        exit(1) # Exit if the transport loop itself crashes
      end

      private

      def handle_line(line, session)
        message = nil # Define outside the begin block for rescue access
        begin
          message = JSON.parse(line)
          server.handle_message(message, session, self) # Pass transport for sending
        rescue JSON::ParserError => e
          logger.error("JSON Parse Error: #{e.message}")
          id = MCPRuby::Util.extract_id_from_invalid_json(line)
          send_error(id, -32_700, "Parse error", nil) if id
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

      def send_response(id, result)
        send_message({ jsonrpc: "2.0", id: id, result: result })
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
