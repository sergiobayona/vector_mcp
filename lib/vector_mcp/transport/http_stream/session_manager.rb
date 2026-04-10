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
            !streaming_connection.nil? || !streaming_connections.empty?
          end

          def streaming_connection
            metadata[:streaming_connection]
          end

          def streaming_connection=(connection)
            metadata[:streaming_connection] = connection
          end

          def streaming_connections
            metadata[:streaming_connections] ||= Concurrent::Hash.new
          end

          def add_streaming_connection(connection)
            streaming_connections[connection.stream_id] = connection
            self.streaming_connection = connection
          end

          def remove_streaming_connection(connection = nil)
            if connection
              streaming_connections.delete(connection.stream_id)
              self.streaming_connection = streaming_connections.values.first if streaming_connection == connection
            else
              streaming_connections.clear
              self.streaming_connection = nil
            end
          end
        end

        # Initializes a new HTTP stream session manager.
        #
        # @param transport [HttpStream] The parent transport instance
        # @param session_timeout [Integer] Session timeout in seconds

        # Optimized session creation with reduced object allocation and faster context creation
        def create_session(session_id = nil, rack_env = nil)
          session_id ||= generate_session_id
          now = Time.now

          # Optimize session context creation - use cached minimal context when rack_env is nil
          session_context = if rack_env
                              create_session_with_context(session_id, rack_env)
                            else
                              create_minimal_session_context(session_id)
                            end

          # Pre-allocate metadata hash for better performance
          metadata = create_session_metadata

          # Create internal session record with streaming connection metadata
          session = Session.new(session_id, session_context, now, now, metadata)

          @sessions[session_id] = session

          logger.info { "Session created: #{session_id}" }
          session
        end

        # Override to add rack_env support.
        # Returns nil when a session_id is provided but not found (expired or unknown).
        # Callers are responsible for returning 404 in that case.
        def get_or_create_session(session_id = nil, rack_env = nil)
          if session_id
            session = get_session(session_id)
            if session
              # Update existing session context if rack_env is provided
              if rack_env
                request_context = VectorMCP::RequestContext.from_rack_env(rack_env, "http_stream")
                session.context.request_context = request_context
              end
              return session
            end

            # Session ID provided but not found — signal 404 to caller
            return nil
          end

          create_session(nil, rack_env)
        end

        # Creates a VectorMCP::Session with proper request context from Rack environment
        def create_session_with_context(session_id, rack_env)
          request_context = VectorMCP::RequestContext.from_rack_env(rack_env, "http_stream")
          VectorMCP::Session.new(@transport.server, @transport, id: session_id, request_context: request_context)
        end

        # Creates a minimal session context for each session (no caching to prevent contamination)
        def create_minimal_session_context(session_id)
          # Create a new minimal context for each session to prevent cross-session contamination
          minimal_context = VectorMCP::RequestContext.minimal("http_stream")
          VectorMCP::Session.new(@transport.server, @transport, id: session_id, request_context: minimal_context)
        end

        # Terminates a session by ID.
        #
        # @param session_id [String] The session ID to terminate
        # @return [Boolean] True if session was found and terminated
        # rubocop:disable Naming/PredicateMethod
        def terminate_session(session_id)
          session = @sessions.delete(session_id)
          return false unless session

          on_session_terminated(session)
          logger.info { "Session terminated: #{session_id}" }
          true
        end
        # rubocop:enable Naming/PredicateMethod

        # Associates a streaming connection with a session.
        #
        # @param session [Session] The session to associate with
        # @param connection [Object] The streaming connection object
        # @return [void]
        def set_streaming_connection(session, connection)
          session.add_streaming_connection(connection)
          session.touch!
          logger.debug { "Streaming connection associated: #{session.id} (stream #{connection.stream_id})" }
        end

        # Removes streaming connection from a session.
        #
        # @param session [Session] The session to remove streaming from
        # @param connection [Object, nil] The specific connection to remove, or nil to clear all
        # @return [void]
        def remove_streaming_connection(session, connection = nil)
          session.remove_streaming_connection(connection)
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
          { streaming_connection: nil, streaming_connections: Concurrent::Hash.new }
        end

        # Override: Checks if a session can receive messages (has streaming connection).
        def can_send_message_to_session?(session)
          session.streaming?
        end

        # Override: Sends a message to a session via the stream handler.
        def message_sent_to_session?(session, message)
          @transport.stream_handler.send_message_to_session(session, message)
        end

        private

        # Closes a session's streaming connection if it exists.
        #
        # @param session [Session] The session whose connection to close
        # @return [void]
        def close_streaming_connection(session)
          return unless session&.streaming?

          connections = session.streaming_connections.values
          connections = [session.streaming_connection] if connections.empty? && session.streaming_connection

          connections.each do |connection|
            connection.close
          rescue StandardError => e
            logger.warn { "Error closing streaming connection for #{session.id}: #{e.message}" }
          end

          session.remove_streaming_connection
        end
      end
    end
  end
end
