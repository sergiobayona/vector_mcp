# frozen_string_literal: true

require "securerandom"
require "concurrent-ruby"

module VectorMCP
  module Transport
    # Base session manager providing unified session lifecycle management across all transports.
    # This abstract base class defines the standard interface that all transport session managers
    # should implement, ensuring consistent session handling regardless of transport type.
    #
    # @abstract Subclass and implement transport-specific methods
    class BaseSessionManager
      # Session data structure for unified session management
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
      end

      attr_reader :transport, :session_timeout, :logger

      # Initializes a new session manager.
      #
      # @param transport [Object] The parent transport instance
      # @param session_timeout [Integer] Session timeout in seconds (default: 300)
      def initialize(transport, session_timeout = 300)
        @transport = transport
        @session_timeout = session_timeout
        @logger = transport.logger
        @sessions = Concurrent::Hash.new
        @cleanup_timer = nil

        start_cleanup_timer if auto_cleanup_enabled?
        logger.debug { "#{self.class.name} initialized with session_timeout: #{session_timeout}" }
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

        # Create internal session record with transport-specific metadata
        session = Session.new(
          session_id,
          session_context,
          now,
          now,
          create_session_metadata
        )

        @sessions[session_id] = session

        logger.info { "Session created: #{session_id}" }
        on_session_created(session)
        session
      end

      # Terminates a session by ID.
      #
      # @param session_id [String] The session ID to terminate
      # @return [Boolean] True if session was found and terminated
      def session_terminated?(session_id)
        session = @sessions.delete(session_id)
        return false unless session

        on_session_terminated(session)
        logger.info { "Session terminated: #{session_id}" }
        true
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

      # Checks if any sessions exist.
      #
      # @return [Boolean] True if at least one session exists
      def sessions?
        !@sessions.empty?
      end

      # Cleans up all sessions and stops the cleanup timer.
      #
      # @return [void]
      def cleanup_all_sessions
        logger.info { "Cleaning up all sessions: #{@sessions.size}" }

        @sessions.each_value do |session|
          on_session_terminated(session)
        end

        @sessions.clear
        stop_cleanup_timer
      end

      # Updates session metadata.
      #
      # @param session_id [String] The session ID
      # @param metadata [Hash] Metadata to merge
      # @return [Boolean] True if session was found and updated
      def session_metadata_updated?(session_id, metadata)
        session = @sessions[session_id]
        return false unless session

        session.metadata.merge!(metadata)
        session.touch!
        true
      end

      # Gets session metadata.
      #
      # @param session_id [String] The session ID
      # @return [Hash, nil] Session metadata or nil if session not found
      def get_session_metadata(session_id)
        session = @sessions[session_id]
        session&.metadata
      end

      # Finds sessions matching criteria.
      #
      # @param criteria [Hash] Search criteria
      # @option criteria [Symbol] :created_after Time to search after
      # @option criteria [Symbol] :metadata Hash of metadata to match
      # @return [Array<Session>] Matching sessions
      def find_sessions(criteria = {})
        @sessions.values.select do |session|
          matches_criteria?(session, criteria)
        end
      end

      # Broadcasts a message to all sessions that support messaging.
      #
      # @param message [Hash] The message to broadcast
      # @return [Integer] Number of sessions the message was sent to
      def broadcast_message(message)
        count = 0
        @sessions.each_value do |session|
          next unless can_send_message_to_session?(session)

          count += 1 if message_sent_to_session?(session, message)
        end

        # Message broadcasted to recipients
        count
      end

      protected

      # Hook called when a session is created. Override in subclasses for transport-specific logic.
      #
      # @param session [Session] The newly created session
      # @return [void]
      def on_session_created(session)
        # Override in subclasses
      end

      # Hook called when a session is terminated. Override in subclasses for transport-specific cleanup.
      #
      # @param session [Session] The session being terminated
      # @return [void]
      def on_session_terminated(session)
        # Override in subclasses
      end

      # Creates transport-specific session metadata. Override in subclasses.
      #
      # @return [Hash] Initial metadata for the session
      def create_session_metadata
        {}
      end

      # Determines if this session manager should enable automatic cleanup.
      # Override in subclasses that don't need automatic cleanup (e.g., stdio with single session).
      #
      # @return [Boolean] True if auto-cleanup should be enabled
      def auto_cleanup_enabled?
        true
      end

      # Checks if a message can be sent to the given session.
      # Override in subclasses based on transport capabilities.
      #
      # @param session [Session] The session to check
      # @return [Boolean] True if messaging is supported for this session
      def can_send_message_to_session?(_session)
        false # Override in subclasses
      end

      # Sends a message to a specific session.
      # Override in subclasses based on transport messaging mechanism.
      #
      # @param session [Session] The target session
      # @param message [Hash] The message to send
      # @return [Boolean] True if message was sent successfully
      def message_sent_to_session?(_session, _message)
        false # Override in subclasses
      end

      private

      # Generates a cryptographically secure session ID.
      #
      # @return [String] A unique session ID
      def generate_session_id
        SecureRandom.uuid
      end

      # Starts the automatic cleanup timer if auto-cleanup is enabled.
      #
      # @return [void]
      def start_cleanup_timer
        return unless auto_cleanup_enabled?

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
          on_session_terminated(session) if session
        end

        return unless expired_sessions.any?

        logger.debug { "Cleaned up expired sessions: #{expired_sessions.size}" }
      end

      # Checks if a session matches the given criteria.
      #
      # @param session [Session] The session to check
      # @param criteria [Hash] The search criteria
      # @return [Boolean] True if session matches all criteria
      def matches_criteria?(session, criteria)
        return false if criteria[:created_after] && session.created_at <= criteria[:created_after]

        criteria[:metadata]&.each do |key, value|
          return false unless session.metadata[key] == value
        end

        true
      end
    end
  end
end
