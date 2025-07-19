# frozen_string_literal: true

# lib/vector_mcp/transport/stdio.rb
require "json"
require_relative "../errors"
require_relative "../util"
require_relative "stdio_session_manager"
require "securerandom" # For generating unique request IDs
require "timeout"      # For request timeouts

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
      # @return [StdioSessionManager] The session manager for this transport.
      attr_reader :session_manager

      # Timeout for waiting for a response to a server-initiated request (in seconds)
      DEFAULT_REQUEST_TIMEOUT = 30 # Configurable if needed

      # Initializes a new Stdio transport.
      #
      # @param server [VectorMCP::Server] The server instance that will handle messages.
      # @param options [Hash] Optional configuration options.
      # @option options [Boolean] :enable_session_manager (false) Whether to enable the unified session manager.
      def initialize(server, options = {})
        @server = server
        @logger = server.logger
        @session_manager = options[:enable_session_manager] ? StdioSessionManager.new(self) : nil
        @input_mutex = Mutex.new
        @output_mutex = Mutex.new
        @running = false
        @input_thread = nil
        @shutdown_requested = false
        @outgoing_request_responses = {} # To store responses for server-initiated requests
        @outgoing_request_conditions = {} # ConditionVariables for server-initiated requests
        @mutex = Mutex.new # To synchronize access to shared response data
        @request_id_generator = Enumerator.new do |y|
          i = 0
          loop { y << "vecmcp_stdio_#{i += 1}_#{SecureRandom.hex(4)}" }
        end
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

      # Sends a JSON-RPC notification message to a specific session.
      # For stdio transport, this behaves the same as send_notification since there's only one session.
      #
      # @param _session_id [String] The session ID (ignored for stdio transport).
      # @param method [String] The method name of the notification.
      # @param params [Hash, Array, nil] The parameters for the notification (optional).
      # @return [Boolean] True if the notification was sent successfully.
      def notification_sent_to_session?(_session_id, method, params = nil)
        send_notification(method, params)
        true
      end

      # Broadcasts a JSON-RPC notification message to all sessions.
      # For stdio transport, this behaves the same as send_notification since there's only one session.
      #
      # @param method [String] The method name of the notification.
      # @param params [Hash, Array, nil] The parameters for the notification (optional).
      # @return [Integer] Number of sessions the notification was sent to (always 1 for stdio).
      def broadcast_notification(method, params = nil)
        send_notification(method, params)
        1
      end

      # Sends a server-initiated JSON-RPC request to the client and waits for a response.
      # This is a blocking call.
      #
      # @param method [String] The request method name.
      # @param params [Hash, Array, nil] The request parameters.
      # @param timeout [Numeric] How long to wait for a response, in seconds.
      # @return [Object] The result part of the client's response.
      # @raise [VectorMCP::SamplingError, VectorMCP::SamplingTimeoutError] if the client returns an error or times out.
      # @raise [ArgumentError] if method is blank.
      def send_request(method, params = nil, timeout: DEFAULT_REQUEST_TIMEOUT)
        raise ArgumentError, "Method cannot be blank" if method.to_s.strip.empty?

        request_id = @request_id_generator.next
        request_payload = { jsonrpc: "2.0", id: request_id, method: method }
        request_payload[:params] = params if params

        setup_request_tracking(request_id)
        logger.debug "[Stdio Transport] Sending request ID #{request_id}: #{method}"
        write_message(request_payload)

        response = wait_for_response(request_id, method, timeout)
        process_response(response, request_id, method)
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
      # Constant identifier for stdio sessions
      def read_input_loop(session)
        while @running
          line = read_input_line
          if line.nil?
            logger.info("End of input ($stdin closed). Shutting down stdio transport.")
            break
          end
          next if line.strip.empty?

          handle_input_line(line, session)
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
      # @return [void]
      def handle_input_line(line, _session)
        message = parse_json(line)
        return if message.is_a?(Array) && message.empty? # Error handled in parse_json, indicated by empty array

        return handle_outgoing_response(message) if outgoing_response?(message)

        handle_server_message(message)
      end

      # Checks if a message is a response to an outgoing request.
      # @api private
      # @param message [Hash] The parsed message.
      # @return [Boolean] True if this is an outgoing response.
      def outgoing_response?(message)
        message["id"] && !message["method"] && (message.key?("result") || message.key?("error"))
      end

      # Gets the global session for this stdio transport.
      # @api private
      # @return [VectorMCP::Session] The current session.
      def session
        # Try session manager first, fallback to old method for backward compatibility
        if @session_manager
          session_wrapper = @session_manager.global_session
          return session_wrapper.context if session_wrapper
        end

        # Fallback to old session creation for backward compatibility
        ensure_session_exists
      end

      # Ensures a global session exists for this stdio transport (legacy method).
      # @api private
      # @return [VectorMCP::Session] The current session.
      def ensure_session_exists
        @ensure_session_exists ||= VectorMCP::Session.new(@server, self, id: "stdio_global_session")
      end

      # Handles a server message with proper error handling.
      # @api private
      # @param message [Hash] The parsed message.
      # @return [void]
      def handle_server_message(message)
        current_session = session
        session_id = current_session.id

        begin
          result = @server.handle_message(message, current_session, session_id)
          send_response(message["id"], result) if message["id"] && result
        rescue VectorMCP::ProtocolError => e
          handle_protocol_error(e, message)
        rescue StandardError => e
          handle_unexpected_error(e, message)
        end
      end

      # --- Run helpers (private) ---

      # Gets the session for the stdio connection.
      # @api private
      # @return [VectorMCP::Session] The session.
      def create_session
        session
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
          logger.error("Fatal error in input thread: #{e.message}")
          exit(1) # Critical failure, exit the server process
        end
      end

      # Cleans up transport resources, ensuring the input thread is stopped.
      # @api private
      # @return [void]
      def shutdown_transport
        @running = false
        @input_thread&.kill if @input_thread&.alive?
        @session_manager&.cleanup_all_sessions
        logger.info("Stdio transport shut down")
      end

      # --- Input helpers (private) ---

      # Handles responses to outgoing requests (like sampling requests).
      # @api private
      # @param message [Hash] The parsed response message.
      # @return [void]
      def handle_outgoing_response(message)
        request_id = message["id"]
        logger.debug "[Stdio Transport] Received response for outgoing request ID #{request_id}"

        @mutex.synchronize do
          # Store the response (convert keys to symbols for consistency)
          response_data = deep_transform_keys(message, &:to_sym)
          @outgoing_request_responses[request_id] = response_data

          # Signal any thread waiting for this response
          condition = @outgoing_request_conditions[request_id]
          if condition
            condition.signal
            logger.debug "[Stdio Transport] Signaled condition for request ID #{request_id}"
          else
            logger.warn "[Stdio Transport] Received response for request ID #{request_id} but no thread is waiting"
          end
        end
      end

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

      # Recursively transforms hash keys using the given block.
      # @api private
      # @param obj [Object] The object to transform (Hash, Array, or other).
      # @return [Object] The transformed object.
      def deep_transform_keys(obj, &block)
        case obj
        when Hash
          obj.transform_keys(&block).transform_values { |v| deep_transform_keys(v, &block) }
        when Array
          obj.map { |v| deep_transform_keys(v, &block) }
        else
          obj
        end
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
          logger.error("Output pipe closed. Cannot send message. Shutting down stdio transport.")
          shutdown # Initiate shutdown as we can no longer communicate
        end
      end

      # Sets up tracking for an outgoing request.
      # @api private
      # @param request_id [String] The request ID to track.
      # @return [void]
      def setup_request_tracking(request_id)
        condition = ConditionVariable.new
        @mutex.synchronize do
          @outgoing_request_conditions[request_id] = condition
        end
      end

      # Waits for a response to an outgoing request.
      # @api private
      # @param request_id [String] The request ID to wait for.
      # @param method [String] The request method name.
      # @param timeout [Numeric] How long to wait.
      # @return [Hash] The response data.
      # @raise [VectorMCP::SamplingTimeoutError] if timeout occurs.
      def wait_for_response(request_id, method, timeout)
        condition = @outgoing_request_conditions[request_id]

        @mutex.synchronize do
          Timeout.timeout(timeout) do
            condition.wait(@mutex) until @outgoing_request_responses.key?(request_id)
            @outgoing_request_responses.delete(request_id)
          end
        rescue Timeout::Error
          logger.warn "[Stdio Transport] Timeout waiting for response to request ID #{request_id} (#{method}) after #{timeout}s"
          @outgoing_request_responses.delete(request_id)
          @outgoing_request_conditions.delete(request_id)
          raise VectorMCP::SamplingTimeoutError, "Timeout waiting for client response to '#{method}' request (ID: #{request_id})"
        ensure
          @outgoing_request_conditions.delete(request_id)
        end
      end

      # Processes the response from an outgoing request.
      # @api private
      # @param response [Hash, nil] The response data.
      # @param request_id [String] The request ID.
      # @param method [String] The request method name.
      # @return [Object] The result data.
      # @raise [VectorMCP::SamplingError] if response contains an error or is nil.
      def process_response(response, request_id, method)
        if response.nil?
          raise VectorMCP::SamplingError, "No response received for '#{method}' request (ID: #{request_id}) - this indicates a logic error."
        end

        if response.key?(:error)
          err = response[:error]
          logger.warn "[Stdio Transport] Client returned error for request ID #{request_id} (#{method}): #{err.inspect}"
          raise VectorMCP::SamplingError, "Client returned an error for '#{method}' request (ID: #{request_id}): [#{err[:code]}] #{err[:message]}"
        end

        response[:result]
      end
    end
  end
end
