# frozen_string_literal: true

require "concurrent-ruby"
require "thread"

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
        StreamingConnection = Struct.new(:session, :queue, :thread, :closed) do
          def initialize(*)
            super
            self.closed ||= false
          end

          def close
            return if closed?

            self.closed = true
            queue << nil
            thread&.kill if thread&.alive?
            thread&.join if thread
          end

          def closed?
            closed
          end
        end

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

          logger.info("Starting SSE stream for session #{session.id}")

          headers = build_sse_headers
          body = create_sse_stream(session, last_event_id)

          [200, headers, body]
        end

        # Sends a message to a specific session.
        #
        # @param session [SessionManager::Session] The target session
        # @param message [Hash] The message to send
        # @return [Boolean] True if message was sent successfully
        def send_message_to_session(session, message)
          return false unless session.streaming?

          connection = @active_connections[session.id]
          return false unless connection && !connection.closed?

          begin
            event_data = message.to_json
            enqueue_event(connection, event_data, "message")
            logger.debug("Message sent to session #{session.id}")
            true
          rescue StandardError => e
            logger.error("Error sending message to session #{session.id}: #{e.message}")
            cleanup_connection(session)
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
        # @return [Enumerator] SSE stream enumerator
        def create_sse_stream(session, last_event_id)
          Enumerator.new do |yielder|
            queue = Queue.new
            connection = StreamingConnection.new(session, queue, nil, false)

            # Register connection
            @active_connections[session.id] = connection
            @transport.session_manager.set_streaming_connection(session, connection)

            # Start streaming thread
            connection.thread = Thread.new do
              begin
                stream_to_client(connection, last_event_id)
              rescue StandardError => e
                logger.error("Error in streaming thread for #{session.id}: #{e.message}")
              ensure
                queue << nil unless connection.closed?
              end
            rescue StandardError => e
              logger.error("Error creating streaming thread for #{session.id}: #{e.message}")
            end

            # Drain queue and send events to client
            loop do
              event = queue.pop
              break if event.nil?

              yielder << event
            end
          ensure
            cleanup_connection(session)
          end
        end

        # Streams events to a client.
        #
        # @param session [SessionManager::Session] The session
        # @param connection [StreamingConnection] The streaming connection
        # @param last_event_id [String, nil] The last event ID for resumability
        # @return [void]
        def stream_to_client(connection, last_event_id)
          session = connection.session
          # Send initial connection event
          connection_event = {
            jsonrpc: "2.0",
            method: "connection/established",
            params: {
              session_id: session.id,
              timestamp: Time.now.iso8601
            }
          }

          enqueue_event(connection, connection_event.to_json, "connection")

          # Replay missed events if resuming
          replay_events(connection, last_event_id) if last_event_id

          # Send periodic keep-alive events
          keep_alive_loop(connection)
        end

        # Replays events after a specific event ID.
        #
        # @param connection [StreamingConnection] The streaming connection
        # @param last_event_id [String] The last event ID received by client
        # @return [void]
        def replay_events(connection, last_event_id)
          session = connection.session
          missed_events = @transport.event_store.get_events_after(session.id, last_event_id)

          logger.info("Replaying #{missed_events.length} missed events from #{last_event_id}")

          missed_events.each do |event|
            connection.queue << event.to_sse_format
          end
        end

        # Keeps the connection alive with periodic heartbeat events.
        #
        # @param connection [StreamingConnection] The streaming connection
        # @return [void]
        def keep_alive_loop(connection)
          session = connection.session
          start_time = Time.now
          max_duration = 300 # 5 minutes maximum connection time

          loop do
            sleep(30) # Send heartbeat every 30 seconds

            current_connection = @active_connections[session.id]
            break if current_connection.nil? || current_connection.closed?

            # Check if connection has been alive too long
            if Time.now - start_time > max_duration
              logger.debug("Connection for #{session.id} reached maximum duration, closing")
              break
            end

            # Send heartbeat
            heartbeat_event = {
              jsonrpc: "2.0",
              method: "heartbeat",
              params: { timestamp: Time.now.iso8601 }
            }

            begin
              enqueue_event(connection, heartbeat_event.to_json, "heartbeat")
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
      def format_sse_event(data, type, event_id)
        lines = []
        lines << "id: #{event_id}"
        lines << "event: #{type}" if type
        lines << "data: #{data}"
        lines << ""
        "#{lines.join("\n")}\n"
      end

        # Enqueues an event for delivery via SSE, storing it for resumability.
        #
        # @param connection [StreamingConnection] The streaming connection
        # @param data [String] JSON-encoded payload
        # @param type [String] SSE event type
        # @return [void]
        def enqueue_event(connection, data, type)
          event_id = @transport.event_store.store_event(connection.session.id, data, type)
          connection.queue << format_sse_event(data, type, event_id) unless connection.closed?
        end

        # Cleans up a specific connection.
        #
        # @param session [SessionManager::Session] The session to clean up
        # @return [void]
        def cleanup_connection(session)
          connection = @active_connections.delete(session.id)
          return unless connection

          connection.close
          @transport.session_manager.remove_streaming_connection(session)

          logger.debug("Streaming connection cleaned up for #{session.id}")
        end
      end
    end
  end
end
