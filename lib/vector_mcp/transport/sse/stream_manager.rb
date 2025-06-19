# frozen_string_literal: true

module VectorMCP
  module Transport
    class SSE
      # Manages Server-Sent Events streaming for client connections.
      # Handles creation of streaming responses and message broadcasting.
      class StreamManager
        class << self
          # Creates an SSE streaming response body for a client connection.
          #
          # @param client_conn [ClientConnection] The client connection to stream to
          # @param endpoint_url [String] The URL for the client to POST messages to
          # @param logger [Logger] Logger instance for debugging
          # @return [Enumerator] Rack-compatible streaming response body
          def create_sse_stream(client_conn, endpoint_url, logger)
            Enumerator.new do |yielder|
              # Send initial endpoint event
              yielder << format_sse_event("endpoint", endpoint_url)
              logger.debug { "Sent endpoint event to client #{client_conn.session_id}: #{endpoint_url}" }

              # Start streaming thread for this client
              client_conn.stream_thread = Thread.new do
                stream_messages_to_client(client_conn, yielder, logger)
              end

              # Keep the connection alive by yielding from the streaming thread
              client_conn.stream_thread.join
            rescue StandardError => e
              logger.error { "Error in SSE stream for client #{client_conn.session_id}: #{e.message}\n#{e.backtrace.join("\n")}" }
            ensure
              logger.debug { "SSE stream ended for client #{client_conn.session_id}" }
              client_conn.close
            end
          end

          # Enqueues a message to a specific client connection.
          #
          # @param client_conn [ClientConnection] The target client connection
          # @param message [Hash] The JSON-RPC message to send
          # @return [Boolean] true if message was enqueued successfully
          def enqueue_message(client_conn, message)
            return false unless client_conn && !client_conn.closed?

            client_conn.enqueue_message(message)
          end

          private

          # Streams messages from a client's queue to the SSE connection.
          # This method runs in a dedicated thread per client.
          #
          # @param client_conn [ClientConnection] The client connection
          # @param yielder [Enumerator::Yielder] The response yielder
          # @param logger [Logger] Logger instance
          def stream_messages_to_client(client_conn, yielder, logger)
            logger.debug { "Starting message streaming thread for client #{client_conn.session_id}" }

            loop do
              message = client_conn.dequeue_message
              break if message.nil? # Queue closed or connection closed

              begin
                json_message = message.to_json
                sse_data = format_sse_event("message", json_message)
                yielder << sse_data

                logger.debug { "Streamed message to client #{client_conn.session_id}: #{json_message}" }
              rescue StandardError => e
                logger.error { "Error streaming message to client #{client_conn.session_id}: #{e.message}" }
                break
              end
            end

            logger.debug { "Message streaming thread ended for client #{client_conn.session_id}" }
          rescue StandardError => e
            logger.error { "Fatal error in streaming thread for client #{client_conn.session_id}: #{e.message}\n#{e.backtrace.join("\n")}" }
          end

          # Formats data as a Server-Sent Event.
          #
          # @param event [String] The event type
          # @param data [String] The event data
          # @return [String] Properly formatted SSE event
          def format_sse_event(event, data)
            "event: #{event}\ndata: #{data}\n\n"
          end
        end
      end
    end
  end
end
