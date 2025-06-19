# frozen_string_literal: true

module VectorMCP
  module Transport
    class SSE
      # Manages individual client connection state for SSE transport.
      # Each client connection has a unique session ID, message queue, and streaming thread.
      class ClientConnection
        attr_reader :session_id, :message_queue, :logger
        attr_accessor :stream_thread, :stream_io

        # Initializes a new client connection.
        #
        # @param session_id [String] Unique identifier for this client session
        # @param logger [Logger] Logger instance for debugging and error reporting
        def initialize(session_id, logger)
          @session_id = session_id
          @logger = logger
          @message_queue = Queue.new
          @stream_thread = nil
          @stream_io = nil
          @closed = false
          @mutex = Mutex.new

          logger.debug { "Client connection created: #{session_id}" }
        end

        # Checks if the connection is closed
        #
        # @return [Boolean] true if connection is closed
        def closed?
          @mutex.synchronize { @closed }
        end

        # Closes the client connection and cleans up resources.
        # This method is thread-safe and can be called multiple times.
        def close
          @mutex.synchronize do
            return if @closed

            @closed = true
            logger.debug { "Closing client connection: #{session_id}" }

            # Close the message queue to signal streaming thread to stop
            @message_queue.close if @message_queue.respond_to?(:close)

            # Close the stream I/O if it exists
            begin
              @stream_io&.close
            rescue StandardError => e
              logger.warn { "Error closing stream I/O for #{session_id}: #{e.message}" }
            end

            # Stop the streaming thread
            if @stream_thread&.alive?
              @stream_thread.kill
              @stream_thread.join(1) # Wait up to 1 second for clean shutdown
            end

            logger.debug { "Client connection closed: #{session_id}" }
          end
        end

        # Enqueues a message to be sent to this client.
        # This method is thread-safe.
        #
        # @param message [Hash] The JSON-RPC message to send
        # @return [Boolean] true if message was enqueued successfully
        def enqueue_message(message)
          return false if closed?

          begin
            @message_queue.push(message)
            logger.debug { "Message enqueued for client #{session_id}: #{message.inspect}" }
            true
          rescue ClosedQueueError
            logger.warn { "Attempted to enqueue message to closed queue for client #{session_id}" }
            false
          rescue StandardError => e
            logger.error { "Error enqueuing message for client #{session_id}: #{e.message}" }
            false
          end
        end

        # Dequeues the next message from the client's message queue.
        # This method blocks until a message is available or the queue is closed.
        #
        # @return [Hash, nil] The next message, or nil if queue is closed
        def dequeue_message
          return nil if closed?

          begin
            @message_queue.pop
          rescue ClosedQueueError
            nil
          rescue StandardError => e
            logger.error { "Error dequeuing message for client #{session_id}: #{e.message}" }
            nil
          end
        end

        # Gets the current queue size
        #
        # @return [Integer] Number of messages waiting in the queue
        def queue_size
          @message_queue.size
        rescue StandardError
          0
        end
      end
    end
  end
end
