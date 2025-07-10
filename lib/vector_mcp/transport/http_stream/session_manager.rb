# frozen_string_literal: true

require "securerandom"
require "concurrent-ruby"

module VectorMCP
  module Transport
    class HttpStream
      # Manages HTTP stream sessions with automatic cleanup and thread safety.
      #
      # Handles:
      # - Session creation and lifecycle management
      # - Thread-safe session storage using concurrent-ruby
      # - Automatic session cleanup based on timeout
      # - Session context integration with VectorMCP::Session
      #
      # @api private
      class SessionManager
        # Session data structure
        Session = Struct.new(:id, :context, :created_at, :last_accessed_at, :streaming_connection) do
          def touch!
            self.last_accessed_at = Time.now
          end

          def expired?(timeout)
            Time.now - last_accessed_at > timeout
          end

          def streaming?
            !streaming_connection.nil?
          end
        end

        attr_reader :transport, :session_timeout, :logger

        # Initializes a new session manager.
        #
        # @param transport [HttpStream] The parent transport instance
        # @param session_timeout [Integer] Session timeout in seconds
        def initialize(transport, session_timeout)
          @transport = transport
          @session_timeout = session_timeout
          @logger = transport.logger
          @sessions = Concurrent::Hash.new
          @cleanup_timer = nil

          start_cleanup_timer
          logger.debug { "SessionManager initialized with session_timeout: #{session_timeout}" }
        end

        # Gets an existing session by ID.
        #
        # @param session_id [String] The session ID
        # @return [Session, nil] The session if found and valid
        def get_session(session_id)
          return nil unless session_id

          session = @sessions[session_id]
          return nil unless session && !session.expired?(@session_timeout)

          session.touch!
          session
        end

        # Gets an existing session or creates a new one.
        #
        # @param session_id [String, nil] The session ID (optional)
        # @return [Session] The existing or newly created session
        def get_or_create_session(session_id = nil)
          if session_id
            session = get_session(session_id)
            return session if session

            # If session_id was provided but not found, create with that ID
            return create_session(session_id)
          end

          create_session
        end

        # Creates a new session.
        #
        # @param session_id [String, nil] Optional specific session ID to use
        # @return [Session] The newly created session
        def create_session(session_id = nil)
          session_id ||= generate_session_id
          now = Time.now

          # Create VectorMCP session context
          session_context = VectorMCP::Session.new(@transport.server, @transport, id: session_id)

          # Create internal session record
          session = Session.new(
            session_id,
            session_context,
            now,
            now,
            nil
          )

          @sessions[session_id] = session

          logger.info { "Session created: #{session_id}" }
          session
        end

        # Terminates a session by ID.
        #
        # @param session_id [String] The session ID to terminate
        # @return [Boolean] True if session was found and terminated
        # rubocop:disable Naming/PredicateMethod
        def terminate_session(session_id)
          session = @sessions.delete(session_id)
          return false unless session

          # Close any streaming connection
          close_streaming_connection(session)

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

        # Broadcasts a message to all sessions with streaming connections.
        #
        # @param message [Hash] The message to broadcast
        # @return [Integer] Number of sessions the message was sent to
        def broadcast_message(message)
          count = 0
          @sessions.each_value do |session|
            next unless session.streaming?

            count += 1 if @transport.stream_handler.send_message_to_session(session, message)
          end

          logger.debug { "Message broadcasted to #{count} recipients" }
          count
        end

        # Gets the current number of active sessions.
        #
        # @return [Integer] Number of active sessions
        def session_count
          @sessions.size
        end

        # Gets all active session IDs.
        #
        # @return [Array<String>] Array of session IDs
        def active_session_ids
          @sessions.keys
        end

        # Cleans up all sessions and stops the cleanup timer.
        #
        # @return [void]
        def cleanup_all_sessions
          logger.info { "Cleaning up all sessions: #{@sessions.size}" }

          @sessions.each_value do |session|
            close_streaming_connection(session)
          end

          @sessions.clear
          stop_cleanup_timer
        end

        private

        # Generates a cryptographically secure session ID.
        #
        # @return [String] A unique session ID
        def generate_session_id
          SecureRandom.uuid
        end

        # Starts the automatic cleanup timer.
        #
        # @return [void]
        def start_cleanup_timer
          # Run cleanup every 60 seconds
          @cleanup_timer = Concurrent::TimerTask.new(execution_interval: 60) do
            cleanup_expired_sessions
          end
          @cleanup_timer.execute
        end

        # Stops the automatic cleanup timer.
        #
        # @return [void]
        def stop_cleanup_timer
          @cleanup_timer&.shutdown
          @cleanup_timer = nil
        end

        # Cleans up expired sessions.
        #
        # @return [void]
        def cleanup_expired_sessions
          expired_sessions = []

          @sessions.each do |session_id, session|
            expired_sessions << session_id if session.expired?(@session_timeout)
          end

          expired_sessions.each do |session_id|
            session = @sessions.delete(session_id)
            close_streaming_connection(session) if session
          end

          return unless expired_sessions.any?

          logger.info { "Cleaned up expired sessions: #{expired_sessions.size}" }
        end

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
