# frozen_string_literal: true

module VectorMCP
  module Middleware
    # Context object passed to middleware hooks containing operation metadata
    # Provides access to request data, session info, and mutable response data
    class Context
      attr_reader :operation_type, :operation_name, :params, :session, :server, :metadata
      attr_accessor :result, :error, :skip_remaining_hooks

      # @param operation_type [Symbol] Type of operation (:tool_call, :resource_read, etc.)
      # @param operation_name [String] Name of the specific operation being performed
      # @param params [Hash] Request parameters
      # @param session [VectorMCP::Session] Current session
      # @param server [VectorMCP::Server] Server instance
      # @param metadata [Hash] Additional metadata about the operation
      def initialize(operation_type:, operation_name:, params:, session:, server:, metadata: {})
        @operation_type = operation_type
        @operation_name = operation_name
        @params = params.dup.freeze # Immutable copy
        @session = session
        @server = server
        @metadata = metadata.dup
        @result = nil
        @error = nil
        @skip_remaining_hooks = false
      end

      # Check if operation completed successfully
      # @return [Boolean] true if no error occurred
      def success?
        @error.nil?
      end

      # Check if operation failed
      # @return [Boolean] true if error occurred
      def error?
        !@error.nil?
      end

      # Get user context from session if available
      # @return [Hash, nil] User context or nil if not authenticated
      def user
        @session&.security_context&.user
      end

      # Get operation timing information
      # @return [Hash] Timing metadata
      def timing
        @metadata[:timing] || {}
      end

      # Add custom metadata
      # @param key [Symbol, String] Metadata key
      # @param value [Object] Metadata value
      def add_metadata(key, value)
        @metadata[key] = value
      end

      # Get all available data as hash for logging/debugging
      # @return [Hash] Context summary
      def to_h
        {
          operation_type: @operation_type,
          operation_name: @operation_name,
          params: @params,
          session_id: @session&.id,
          metadata: @metadata,
          success: success?,
          error: @error&.class&.name
        }
      end
    end
  end
end
