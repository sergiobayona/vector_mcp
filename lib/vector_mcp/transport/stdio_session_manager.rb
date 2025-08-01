# frozen_string_literal: true

require_relative "base_session_manager"

module VectorMCP
  module Transport
    # Session manager for Stdio transport with single global session.
    # Extends BaseSessionManager with stdio-specific functionality.
    #
    # The Stdio transport uses a single global session for the entire transport lifetime.
    class StdioSessionManager < BaseSessionManager
      GLOBAL_SESSION_ID = "stdio_global_session"

      # Initializes a new Stdio session manager.
      #
      # @param transport [Stdio] The parent transport instance
      # @param session_timeout [Integer] Session timeout in seconds (ignored for stdio)
      def initialize(transport, session_timeout = 300)
        super

        # Create the single global session for stdio transport
        @global_session = create_global_session
      end

      # Gets the global session for stdio transport.
      # Stdio uses a single global session for the entire transport lifetime.
      #
      # @return [Session] The global session
      def global_session
        @global_session&.touch!
        @global_session
      end

      # Gets or creates the global session for stdio transport.
      # This is an alias for global_session for stdio transport.
      #
      # @return [Session] The global session
      def global_session_or_create
        global_session
      end

      # Override: Gets session by ID, but always returns the global session for stdio.
      #
      # @param session_id [String] The session ID (ignored for stdio)
      # @return [Session] The global session
      def session(_session_id = nil)
        global_session
      end

      # Override: Always returns the global session for stdio.
      #
      # @param session_id [String, nil] The session ID (ignored)
      # @return [Session] The global session
      def session_or_create(_session_id = nil)
        global_session
      end

      # Override: Cannot create additional sessions in stdio transport.
      #
      # @param session_id [String, nil] The session ID (ignored)
      # @return [Session] The global session
      def create_session(_session_id = nil)
        # For stdio, always return the existing global session
        global_session
      end

      # Override: Cannot terminate the global session while transport is running.
      #
      # @param session_id [String] The session ID (ignored)
      # @return [Boolean] Always false (session cannot be terminated individually)
      def session_terminated?(_session_id)
        # For stdio, the session is only terminated when the transport shuts down
        false
      end

      # Override: Always returns 1 for the single global session.
      #
      # @return [Integer] Always 1
      def session_count
        1
      end

      # Override: Always returns the global session ID.
      #
      # @return [Array<String>] Array containing the global session ID
      def active_session_ids
        [GLOBAL_SESSION_ID]
      end

      # Override: Always returns true for the single session.
      #
      # @return [Boolean] Always true
      def sessions?
        true
      end

      # Gets all sessions for stdio transport (just the one global session).
      #
      # @return [Array<Session>] Array containing the global session
      def all_sessions
        [@global_session].compact
      end

      # Alias for global_session for compatibility with tests.
      #
      # @return [Session] The global session
      def current_global_session
        global_session
      end

      # Alias for global_session_or_create for compatibility with tests.
      #
      # @return [Session] The global session
      def global_session_or_create_current
        global_session_or_create
      end

      # Alias for all_sessions for compatibility with tests.
      #
      # @return [Array<Session>] Array containing the global session
      def current_all_sessions
        all_sessions
      end

      protected

      # Override: Stdio doesn't need automatic cleanup since it has a single persistent session.
      def auto_cleanup_enabled?
        false
      end

      # Override: Returns metadata for stdio sessions.
      def create_session_metadata
        { session_type: :stdio_global, created_via: :transport_startup }
      end

      # Override: Stdio can always send messages (single session assumption).
      def can_send_message_to_session?(_session)
        true
      end

      # Override: Sends messages via the transport's notification mechanism.
      def message_sent_to_session?(_session, message)
        # For stdio, we send notifications directly via the transport
        @transport.send_notification(message["method"], message["params"])
        true
      end

      # Override: Stdio broadcasts to the single session (same as regular send).
      def broadcast_message(message)
        message_sent_to_session?(@global_session, message) ? 1 : 0
      end

      private

      # Creates the single global session for stdio transport.
      #
      # @return [BaseSessionManager::Session] The global session
      def create_global_session
        now = Time.now

        # Create VectorMCP session context with minimal request context
        request_context = VectorMCP::RequestContext.minimal("stdio")
        session_context = VectorMCP::Session.new(@transport.server, @transport, id: GLOBAL_SESSION_ID, request_context: request_context)

        # Create internal session record using base session manager struct
        session = BaseSessionManager::Session.new(
          GLOBAL_SESSION_ID,
          session_context,
          now,
          now,
          create_session_metadata
        )

        @sessions[GLOBAL_SESSION_ID] = session
        logger.info { "Global stdio session created: #{GLOBAL_SESSION_ID}" }
        session
      end
    end
  end
end
