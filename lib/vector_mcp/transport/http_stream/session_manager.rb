# frozen_string_literal: true

require "securerandom"
require "concurrent-ruby"
require_relative "../base_session_manager"

module VectorMCP
  module Transport
    class HttpStream
      # Manages HTTP stream sessions with automatic cleanup and thread safety.
      # Extends BaseSessionManager with HTTP streaming-specific functionality.
      #
      # Handles:
      # - Session creation and lifecycle management
      # - Thread-safe session storage using concurrent-ruby
      # - Automatic session cleanup based on timeout
      # - Session context integration with VectorMCP::Session
      # - HTTP streaming connection management
      #
      # @api private
      class SessionManager < BaseSessionManager
        # HTTP stream session data structure extending base session
        Session = Struct.new(:id, :context, :created_at, :last_accessed_at, :metadata) do
          def touch!
            self.last_accessed_at = Time.now
          end

          def expired?(timeout)
            Time.now - last_accessed_at > timeout
          end

          def age
            Time.now - created_at
          end

          def streaming?
            metadata[:streaming_connection] && !metadata[:streaming_connection].nil?
          end

          def streaming_connection
            metadata[:streaming_connection]
          end

          def streaming_connection=(connection)
            metadata[:streaming_connection] = connection
          end
        end

        # Initializes a new HTTP stream session manager.
        #
        # @param transport [HttpStream] The parent transport instance
        # @param session_timeout [Integer] Session timeout in seconds
        def initialize(transport, session_timeout)
          super(transport, session_timeout)
        end

        # Overrides base implementation to create HTTP stream sessions with streaming connection metadata.
        def create_session(session_id = nil)
          session_id ||= generate_session_id
          now = Time.now

          # Create VectorMCP session context
          session_context = VectorMCP::Session.new(@transport.server, @transport, id: session_id)

          # Create internal session record with streaming connection metadata
          session = Session.new(
            session_id,
            session_context,
            now,
            now,
            { streaming_connection: nil }
          )

          @sessions[session_id] = session

          logger.info { "Session created: #{session_id}" }
          session
        end

        # Associates a streaming connection with a session.
        #
        # @param session [Session] The session to associate with
        # @param connection [Object] The streaming connection object
        # @return [void]
        def set_streaming_connection(session, connection)
          session.streaming_connection = connection
          session.touch!
          logger.debug { "Streaming connection associated: #{session.id}" }
        end

        # Removes streaming connection from a session.
        #
        # @param session [Session] The session to remove streaming from
        # @return [void]
        def remove_streaming_connection(session)
          session.streaming_connection = nil
          session.touch!
          logger.debug { "Streaming connection removed: #{session.id}" }
        end

        protected

        # Override: Called when a session is terminated to clean up streaming connections.
        def on_session_terminated(session)
          close_streaming_connection(session)
        end

        # Override: Returns metadata for new HTTP stream sessions.
        def create_session_metadata
          { streaming_connection: nil }
        end

        # Override: Checks if a session can receive messages (has streaming connection).
        def can_send_message_to_session?(session)
          session.streaming?
        end

        # Override: Sends a message to a session via the stream handler.
        def send_message_to_session(session, message)
          @transport.stream_handler.send_message_to_session(session, message)
        end

        private

        # Closes a session's streaming connection if it exists.
        #
        # @param session [Session] The session whose connection to close
        # @return [void]
        def close_streaming_connection(session)
          return unless session&.streaming_connection

          begin
            session.streaming_connection.close
          rescue StandardError => e
            logger.warn { "Error closing streaming connection for #{session.id}: #{e.message}" }
          end

          session.streaming_connection = nil
        end
      end
    end
  end
end
