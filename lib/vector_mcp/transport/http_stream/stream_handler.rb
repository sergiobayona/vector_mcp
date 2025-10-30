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
        StreamingConnection = Struct.new(:session, :queue, :thread, :closed) do
          def initialize(*)
            super
            self.closed ||= false
            self.queue ||= Queue.new
          end

          def close
            return if closed?

            self.closed = true
            queue << nil # Queue natively supports <<
            thread&.kill
            thread&.join
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
          return false unless connection
          return false if connection.respond_to?(:closed?) && connection.closed?

          begin
            event_data = message.to_json
            enqueue_event(connection, session, event_data, "message")
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
          connection_event = {
            jsonrpc: "2.0",
            method: "connection/established",
            params: {
              session_id: session.id,
              timestamp: Time.now.iso8601
            }
          }

          enqueue_event(connection, session, connection_event.to_json, "connection")
          replay_events(connection, last_event_id) if last_event_id
          keep_alive_loop(connection)
        end

        # Replays events after a specific event ID.
        def replay_events(connection_or_session, last_event_id_or_target, maybe_last_event_id = nil)
          if connection_or_session.is_a?(StreamingConnection)
            connection = connection_or_session
            session = connection.session
            target = delivery_target(connection)
            last_event_id = last_event_id_or_target
          else
            session = connection_or_session
            connection = @active_connections[session.id]
            target = last_event_id_or_target
            last_event_id = maybe_last_event_id
          end

          return unless last_event_id

          missed_events = @transport.event_store.get_events_after(session.id, last_event_id)
          logger.info("Replaying #{missed_events.length} missed events from #{last_event_id}")

          missed_events.each do |event|
            payload = event.to_sse_format
            if target
              target << payload
            elsif connection
              delivery_target(connection)&.<< payload
            end
          end
        end

        # Keeps the connection alive with periodic heartbeat events.
        def keep_alive_loop(connection_or_session, maybe_target = nil)
          connection, session, target = extract_connection_info(connection_or_session, maybe_target)
          return unless session

          start_time = Time.now
          max_duration = 300 # 5 minutes maximum connection time

          loop do
            sleep(30) # Send heartbeat every 30 seconds

            break if connection_expired?(connection, session, start_time, max_duration)

            send_heartbeat(connection, session, target)
          rescue StandardError
            logger.debug("Heartbeat failed for #{session.id}, connection likely closed")
            break
          end
        end

        # Extracts connection info from the connection_or_session parameter.
        #
        # @param connection_or_session [StreamingConnection, SessionManager::Session] Connection or session
        # @param maybe_target [Queue, nil] Optional target queue
        # @return [Array(StreamingConnection, SessionManager::Session, Queue)] Connection, session, target
        def extract_connection_info(connection_or_session, maybe_target)
          if connection_or_session.is_a?(StreamingConnection)
            connection = connection_or_session
            session = connection.session
            target = delivery_target(connection)
          else
            session = connection_or_session
            connection = @active_connections[session.id]
            target = maybe_target
          end

          [connection, session, target]
        end

        # Checks if a connection has expired or been closed.
        #
        # @param connection [StreamingConnection, nil] The connection
        # @param session [SessionManager::Session] The session
        # @param start_time [Time] When the connection started
        # @param max_duration [Integer] Maximum duration in seconds
        # @return [Boolean] True if the connection should be closed
        def connection_expired?(connection, session, start_time, max_duration)
          current_connection = connection ? @active_connections[session.id] : nil
          return true if connection && (current_connection.nil? || current_connection.closed?)

          if Time.now - start_time > max_duration
            logger.debug("Connection for #{session.id} reached maximum duration, closing")
            return true
          end

          false
        end

        # Sends a heartbeat event to the client.
        #
        # @param connection [StreamingConnection, nil] The connection
        # @param session [SessionManager::Session] The session
        # @param target [Queue, nil] Optional target queue
        # @return [void]
        def send_heartbeat(connection, session, target)
          heartbeat_event = {
            jsonrpc: "2.0",
            method: "heartbeat",
            params: { timestamp: Time.now.iso8601 }
          }

          payload = heartbeat_event.to_json
          current_connection = connection ? @active_connections[session.id] : nil

          if target
            event_id = @transport.event_store.store_event(session.id, payload, "heartbeat")
            target << format_sse_event(payload, "heartbeat", event_id)
          elsif current_connection
            enqueue_event(current_connection, session, payload, "heartbeat")
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
        def enqueue_event(connection, session, data, type)
          return if connection.respond_to?(:closed?) && connection.closed?

          event_id = @transport.event_store.store_event(session.id, data, type)
          target = delivery_target(connection)
          raise StandardError, "No streaming target available" unless target

          target << format_sse_event(data, type, event_id)
        end

        # Gets the delivery target (queue) for a connection.
        #
        # @param connection [StreamingConnection] The streaming connection
        # @return [Queue, nil] The queue for event delivery
        def delivery_target(connection)
          connection.queue if connection.is_a?(StreamingConnection)
        end

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
