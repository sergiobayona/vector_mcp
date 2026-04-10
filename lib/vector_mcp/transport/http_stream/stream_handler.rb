# frozen_string_literal: true

require "concurrent-ruby"

module VectorMCP
  module Transport
    class HttpStream
      # Handles Server-Sent Events streaming for HTTP transport.
      #
      # Manages:
      # - SSE connection lifecycle
      # - Event streaming with resumability
      # - Last-Event-ID header processing
      # - Connection health monitoring
      #
      # @api private
      class StreamHandler
        attr_reader :transport, :logger

        # Streaming connection data structure
        StreamingConnection = Struct.new(:session, :yielder, :thread, :closed, :origin, :stream_id) do
          def close
            self.closed = true
            thread&.kill
          end

          def closed?
            closed
          end

          # Returns true if this connection originated from a GET request.
          def from_get?
            origin == :get
          end
        end

        # Default reconnection time in milliseconds sent before intentional disconnections.
        DEFAULT_RETRY_MS = 5000

        # Initializes a new stream handler.
        #
        # @param transport [HttpStream] The parent transport instance
        def initialize(transport)
          @transport = transport
          @logger = transport.logger
          @active_connections = Concurrent::Hash.new
        end

        # Handles a streaming request (GET request for SSE).
        #
        # @param env [Hash] The Rack environment
        # @param session [SessionManager::Session] The session for this request
        # @return [Array] Rack response triplet for SSE
        def handle_streaming_request(env, session)
          last_event_id = extract_last_event_id(env)
          stream_id = resolve_stream_id(session, last_event_id, :get)

          logger.info("Starting SSE stream for session #{session.id}")

          headers = build_sse_headers
          body = create_sse_stream(session, last_event_id, stream_id: stream_id)

          [200, headers, body]
        end

        # Sends a message to a specific session.
        #
        # @param session [SessionManager::Session] The target session
        # @param message [Hash] The message to send
        # @return [Boolean] True if message was sent successfully
        def send_message_to_session(session, message)
          return false unless session.streaming?

          connection = select_connection_for_message(session, message)
          return false unless connection

          begin
            # Store event for resumability
            event_data = message.to_json
            event_id = @transport.event_store.store_event(event_data, "message",
                                                          session_id: session.id,
                                                          stream_id: connection.stream_id)

            # Send via SSE
            sse_event = format_sse_event(event_data, "message", event_id)
            connection.yielder << sse_event

            logger.debug("Message sent to session #{session.id}")

            true
          rescue StandardError => e
            logger.error("Error sending message to session #{session.id}: #{e.message}")

            # Mark connection as closed and clean up
            cleanup_connection(session, connection)
            false
          end
        end

        # Gets the number of active streaming connections.
        #
        # @return [Integer] Number of active connections
        def active_connection_count
          @active_connections.size
        end

        # Cleans up all active connections.
        #
        # @return [void]
        def cleanup_all_connections
          logger.info("Cleaning up all streaming connections: #{@active_connections.size}")

          @active_connections.each_value(&:close)

          @active_connections.clear
        end

        private

        # Extracts Last-Event-ID from request headers.
        #
        # @param env [Hash] The Rack environment
        # @return [String, nil] The last event ID or nil
        def extract_last_event_id(env)
          env["HTTP_LAST_EVENT_ID"]
        end

        # Builds SSE response headers.
        #
        # @return [Hash] SSE headers
        def build_sse_headers
          {
            "Content-Type" => "text/event-stream",
            "Cache-Control" => "no-cache",
            "Connection" => "keep-alive",
            "X-Accel-Buffering" => "no",
            "Access-Control-Allow-Origin" => "*",
            "Access-Control-Allow-Headers" => "Last-Event-ID"
          }
        end

        # Creates an SSE stream for a session.
        #
        # @param session [SessionManager::Session] The session
        # @param last_event_id [String, nil] The last event ID for resumability
        # @param origin [Symbol] The stream origin (:get or :post)
        # @return [Enumerator] SSE stream enumerator
        def create_sse_stream(session, last_event_id, origin: :get, stream_id: nil)
          stream_id ||= generate_stream_id(session.id, origin)

          Enumerator.new do |yielder|
            connection = StreamingConnection.new(session, yielder, nil, false, origin, stream_id)

            # Register connection
            replace_existing_connection(session, stream_id)
            @active_connections[stream_id] = connection
            @transport.session_manager.set_streaming_connection(session, connection)

            # Start streaming thread
            connection.thread = Thread.new do
              stream_to_client(session, yielder, last_event_id, stream_id)
            rescue StandardError => e
              logger.error("Error in streaming thread for #{session.id}: #{e.message}")
            ensure
              cleanup_connection(session, connection)
            end

            # Keep connection alive until thread completes
            connection.thread.join
          end
        end

        # Streams events to a client.
        #
        # @param session [SessionManager::Session] The session
        # @param yielder [Enumerator::Yielder] The SSE yielder
        # @param last_event_id [String, nil] The last event ID for resumability
        # @param stream_id [String] The unique stream identifier
        # @return [void]
        def stream_to_client(session, yielder, last_event_id, stream_id)
          # SSE priming event per MCP spec: event ID + empty data field
          prime_event_id = @transport.event_store.store_event("", nil, session_id: session.id, stream_id: stream_id)
          yielder << "id: #{prime_event_id}\ndata:\n\n"

          # Replay missed events if resuming — scoped to the original stream only
          replay_events(yielder, last_event_id, session, stream_id) if last_event_id

          # Send periodic keep-alive events
          keep_alive_loop(session, yielder, stream_id)
        end

        # Replays events after a specific event ID, scoped to the originating stream.
        #
        # @param yielder [Enumerator::Yielder] The SSE yielder
        # @param last_event_id [String] The last event ID received by client
        # @param session [SessionManager::Session] The session to filter events for
        # @param stream_id [String] The logical stream ID being resumed
        # @return [void]
        def replay_events(yielder, last_event_id, session, stream_id)
          missed_events = @transport.event_store.get_events_after(
            last_event_id,
            session_id: session.id,
            stream_id: stream_id
          )

          logger.info("Replaying #{missed_events.length} missed events from #{last_event_id}")

          missed_events.each do |event|
            yielder << event.to_sse_format
          end
        end

        # Keeps the connection alive with periodic heartbeat events.
        #
        # @param session [SessionManager::Session] The session
        # @param yielder [Enumerator::Yielder] The SSE yielder
        # @param stream_id [String] The stream ID for event storage
        # @return [void]
        def keep_alive_loop(session, yielder, stream_id)
          start_time = Time.now
          max_duration = 300 # 5 minutes maximum connection time

          loop do
            sleep(30) # Send heartbeat every 30 seconds

            connection = @active_connections[stream_id] || @active_connections[session.id]
            break if connection.nil? || connection.closed?

            # Check if connection has been alive too long
            if Time.now - start_time > max_duration
              logger.debug("Connection for #{session.id} reached maximum duration, sending retry guidance and closing")
              # Send retry field before intentional disconnect per MCP spec
              yielder << "retry: #{DEFAULT_RETRY_MS}\n\n"
              break
            end

            # Send heartbeat as SSE comment (not a JSON-RPC notification)
            begin
              yielder << ": heartbeat\n\n"
            rescue StandardError
              logger.debug("Heartbeat failed for #{session.id}, connection likely closed")
              break
            end
          end
        end

        # Formats data as an SSE event.
        #
        # @param data [String] The event data
        # @param type [String] The event type
        # @param event_id [String] The event ID
        # @return [String] Formatted SSE event
        def format_sse_event(data, type, event_id, retry_ms: nil)
          lines = []
          lines << "id: #{event_id}" if event_id
          lines << "event: #{type}" if type
          lines << "retry: #{retry_ms}" if retry_ms
          lines << "data: #{data}"
          lines << ""
          "#{lines.join("\n")}\n"
        end

        # Checks if a message is a JSON-RPC response (has result or error, no method).
        #
        # @param message [Hash] The JSON-RPC message
        # @return [Boolean] True if the message is a response
        def json_rpc_response?(message)
          return false unless message.is_a?(Hash)

          (message.key?("result") || message.key?(:result) ||
           message.key?("error") || message.key?(:error)) &&
            !message.key?("method") && !message.key?(:method)
        end

        # Cleans up a specific connection.
        #
        # @param session [SessionManager::Session] The session to clean up
        # @return [void]
        def cleanup_connection(session, connection = nil)
          connection ||= session.streaming_connection
          connection ||= @active_connections[session.id]
          return unless connection

          @active_connections.delete(connection.stream_id)
          @active_connections.delete(session.id) if @active_connections[session.id] == connection

          connection.close
          @transport.session_manager.remove_streaming_connection(session, connection)

          logger.debug("Streaming connection cleaned up for #{session.id}")
        end

        def resolve_stream_id(session, last_event_id, origin)
          return generate_stream_id(session.id, origin) unless last_event_id

          last_event = @transport.event_store.get_event(last_event_id)

          if last_event && last_event.session_id == session.id && last_event.stream_id
            last_event.stream_id
          else
            generate_stream_id(session.id, origin)
          end
        end

        def generate_stream_id(session_id, origin)
          "#{session_id}-#{origin}-#{SecureRandom.hex(4)}"
        end

        def select_connection_for_message(session, message)
          connections = active_connections_for_session(session)
          return nil if connections.empty?

          if json_rpc_response?(message)
            eligible_connections = connections.reject(&:from_get?)
            if eligible_connections.empty?
              logger.debug("Blocked JSON-RPC response on GET stream for session #{session.id}")
              return nil
            end

            preferred_connection_for(session, eligible_connections)
          else
            preferred_connection_for(session, connections)
          end
        end

        def active_connections_for_session(session)
          connections = session.streaming_connections.values.select do |connection|
            @active_connections[connection.stream_id] == connection && !connection.closed?
          end

          legacy_connection = @active_connections[session.id]
          connections << legacy_connection if legacy_connection &&
                                              !legacy_connection.closed? &&
                                              !connections.include?(legacy_connection)

          connections
        end

        def preferred_connection_for(session, connections)
          preferred = session.streaming_connection
          return connections.find { |connection| connection == preferred } if preferred && connections.include?(preferred)

          connections.first
        end

        def replace_existing_connection(session, stream_id)
          existing_connection = @active_connections[stream_id]
          return unless existing_connection

          cleanup_connection(session, existing_connection)
        end
      end
    end
  end
end
