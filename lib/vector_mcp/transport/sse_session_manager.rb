# frozen_string_literal: true

require_relative "base_session_manager"

module VectorMCP
  module Transport
    # Session manager for SSE transport with single shared session and client connection management.
    # Extends BaseSessionManager with SSE-specific functionality.
    #
    # The SSE transport uses a single shared session for all client connections,
    # but manages multiple client connections separately.
    class SseSessionManager < BaseSessionManager
      attr_reader :clients

      # Initializes a new SSE session manager.
      #
      # @param transport [SSE] The parent transport instance
      # @param session_timeout [Integer] Session timeout in seconds
      def initialize(transport, session_timeout = 300)
        @clients = Concurrent::Hash.new
        super

        # Create the single shared session for SSE transport
        @shared_session = create_shared_session
      end

      # Gets the shared session for SSE transport.
      # SSE uses a single session shared across all client connections.
      #
      # @return [Session] The shared session
      def shared_session
        @shared_session.touch!
        @shared_session
      end

      # Registers a client connection with the session manager.
      #
      # @param client_id [String] The client connection ID
      # @param client_connection [Object] The client connection object
      # @return [void]
      def register_client(client_id, client_connection)
        @clients[client_id] = client_connection
        session_metadata_updated?(@shared_session.id, clients_count: @clients.size)
        logger.debug { "Client registered: #{client_id}" }
      end

      # Unregisters a client connection from the session manager.
      #
      # @param client_id [String] The client connection ID
      # @return [Boolean] True if client was found and removed
      def client_unregistered?(client_id)
        client = @clients.delete(client_id)
        return false unless client

        session_metadata_updated?(@shared_session.id, clients_count: @clients.size)
        logger.debug { "Client unregistered: #{client_id}" }
        true
      end

      # Gets all client connections.
      #
      # @return [Hash] Hash of client_id => client_connection
      def all_clients
        @clients.dup
      end

      # Gets the number of connected clients.
      #
      # @return [Integer] Number of connected clients
      def client_count
        @clients.size
      end

      # Cleans up all clients and the shared session.
      #
      # @return [void]
      def cleanup_all_sessions
        logger.info { "Cleaning up #{@clients.size} client connection(s)" }

        @clients.each_value do |client_conn|
          close_client_connection(client_conn)
        end
        @clients.clear

        super
      end

      protected

      # Override: SSE doesn't need automatic cleanup since it has a single shared session.
      def auto_cleanup_enabled?
        false
      end

      # Override: Called when the shared session is terminated.
      def on_session_terminated(_session)
        # Clean up all client connections when session is terminated
        @clients.each_value do |client_conn|
          close_client_connection(client_conn)
        end
        @clients.clear
      end

      # Override: Returns metadata for SSE sessions.
      def create_session_metadata
        { clients_count: 0, session_type: :sse_shared }
      end

      # Override: Checks if any clients are connected to receive messages.
      def can_send_message_to_session?(_session)
        !@clients.empty?
      end

      # Override: Sends a message to the first available client.
      def send_message_to_session(_session, message)
        return false if @clients.empty?

        first_client = @clients.values.first
        return false unless first_client

        @transport.class::StreamManager.enqueue_message(first_client, message)
      end

      # Override: Broadcasts messages to all connected clients.
      def broadcast_message(message)
        count = 0
        @clients.each_value do |client_conn|
          count += 1 if @transport.class::StreamManager.enqueue_message(client_conn, message)
        end

        logger.debug { "Message broadcasted to #{count} client(s)" }
        count
      end

      private

      # Creates the single shared session for SSE transport.
      #
      # @return [BaseSessionManager::Session] The shared session
      def create_shared_session(rack_env = nil)
        session_id = "sse_shared_session_#{SecureRandom.uuid}"
        now = Time.now

        # Create VectorMCP session context with request context
        session_context = create_session_with_context(session_id, rack_env)

        # Create internal session record using base session manager struct
        session = BaseSessionManager::Session.new(
          session_id,
          session_context,
          now,
          now,
          create_session_metadata
        )

        @sessions[session_id] = session
        logger.info { "Shared SSE session created: #{session_id}" }
        session
      end

      # Creates a VectorMCP::Session with proper request context from Rack environment
      def create_session_with_context(session_id, rack_env)
        request_context = if rack_env
                            # Create request context from Rack environment
                            VectorMCP::RequestContext.from_rack_env(rack_env, "sse")
                          else
                            # Fallback to minimal context for cases where rack_env is not available
                            VectorMCP::RequestContext.minimal("sse")
                          end
        VectorMCP::Session.new(@transport.server, @transport, id: session_id, request_context: request_context)
      end

      # Closes a client connection safely.
      #
      # @param client_conn [Object] The client connection to close
      # @return [void]
      def close_client_connection(client_conn)
        return unless client_conn

        begin
          client_conn.close if client_conn.respond_to?(:close)
        rescue StandardError => e
          logger.warn { "Error closing client connection: #{e.message}" }
        end
      end
    end
  end
end
