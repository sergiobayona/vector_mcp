# frozen_string_literal: true

module VectorMCP
  module Security
    # Represents the security context for a user session
    # Contains authentication and authorization information
    class SessionContext
      attr_reader :user, :authenticated, :permissions, :auth_strategy, :authenticated_at

      # Initialize session context
      # @param user [Object] the authenticated user object
      # @param authenticated [Boolean] whether the user is authenticated
      # @param auth_strategy [String] the authentication strategy used
      # @param authenticated_at [Time] when authentication occurred
      def initialize(user: nil, authenticated: false, auth_strategy: nil, authenticated_at: nil)
        @user = user
        @authenticated = authenticated
        @auth_strategy = auth_strategy
        @authenticated_at = authenticated_at || Time.now
        @permissions = Set.new
      end

      # Check if the session is authenticated
      # @return [Boolean] true if authenticated
      def authenticated?
        @authenticated
      end

      # Check if the user has a specific permission
      # @param permission [String, Symbol] the permission to check
      # @return [Boolean] true if user has the permission
      def can?(permission)
        @permissions.include?(permission.to_s)
      end

      # Check if the user can perform an action on a resource
      # @param action [String, Symbol] the action (e.g., 'read', 'write', 'execute')
      # @param resource [String, Symbol] the resource (e.g., 'tools', 'resources')
      # @return [Boolean] true if user can perform the action
      def can_access?(action, resource)
        can?("#{action}:#{resource}") || can?("#{action}:*") || can?("*:#{resource}") || can?("*:*")
      end

      # Add a permission to the session
      # @param permission [String, Symbol] the permission to add
      def add_permission(permission)
        @permissions << permission.to_s
      end

      # Add multiple permissions to the session
      # @param permissions [Array<String, Symbol>] the permissions to add
      def add_permissions(permissions)
        permissions.each { |perm| add_permission(perm) }
      end

      # Remove a permission from the session
      # @param permission [String, Symbol] the permission to remove
      def remove_permission(permission)
        @permissions.delete(permission.to_s)
      end

      # Clear all permissions
      def clear_permissions
        @permissions.clear
      end

      # Get user identifier for logging/auditing
      # @return [String] a string identifying the user
      def user_identifier
        return "anonymous" unless authenticated?
        return "anonymous" if @user.nil?

        case @user
        when Hash
          @user[:user_id] || @user[:sub] || @user[:email] || @user[:api_key] || "authenticated_user"
        when String
          @user
        else
          @user.respond_to?(:id) ? @user.id.to_s : "authenticated_user"
        end
      end

      # Get authentication method used
      # @return [String] the authentication strategy
      def auth_method
        @auth_strategy || "none"
      end

      # Check if authentication is recent (within specified seconds)
      # @param max_age [Integer] maximum age in seconds (default: 3600 = 1 hour)
      # @return [Boolean] true if authentication is recent
      def auth_recent?(max_age: 3600)
        return false unless authenticated?

        (Time.now - @authenticated_at) <= max_age
      end

      # Convert to hash for serialization
      # @return [Hash] session context as hash
      def to_h
        {
          authenticated: @authenticated,
          user_identifier: user_identifier,
          auth_strategy: @auth_strategy,
          authenticated_at: @authenticated_at&.iso8601,
          permissions: @permissions.to_a
        }
      end

      # Create an anonymous (unauthenticated) session context
      # @return [SessionContext] an unauthenticated session
      def self.anonymous
        new(authenticated: false)
      end

      # Create an authenticated session context from auth result
      # @param auth_result [Hash] the authentication result
      # @return [SessionContext] an authenticated session
      def self.from_auth_result(auth_result)
        return anonymous unless auth_result&.dig(:authenticated)

        user_data = auth_result[:user]

        # Handle special marker for authenticated nil user
        if user_data == :authenticated_nil_user
          new(
            user: nil,
            authenticated: true,
            auth_strategy: "custom",
            authenticated_at: Time.now
          )
        else
          # Extract strategy and authenticated_at only if user_data is a Hash
          strategy = user_data.is_a?(Hash) ? user_data[:strategy] : nil
          auth_time = user_data.is_a?(Hash) ? user_data[:authenticated_at] : nil

          new(
            user: user_data,
            authenticated: true,
            auth_strategy: strategy,
            authenticated_at: auth_time
          )
        end
      end
    end
  end
end
