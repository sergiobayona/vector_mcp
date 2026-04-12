# frozen_string_literal: true

module VectorMCP
  module Security
    # Value object representing the outcome of an authentication attempt.
    # Replaces the unstructured Hash that previously flowed through the auth pipeline.
    class AuthResult
      attr_reader :user, :strategy, :authenticated_at

      def initialize(authenticated:, user: nil, strategy: nil, authenticated_at: nil)
        @authenticated = authenticated
        @user = user
        @strategy = strategy
        @authenticated_at = authenticated_at || (Time.now if authenticated)
        freeze
      end

      def authenticated? = @authenticated

      def self.success(user:, strategy:, authenticated_at: Time.now)
        new(authenticated: true, user: user, strategy: strategy, authenticated_at: authenticated_at)
      end

      def self.failure
        new(authenticated: false)
      end

      def self.passthrough
        new(authenticated: true)
      end
    end
  end
end
