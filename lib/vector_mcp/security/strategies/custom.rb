# frozen_string_literal: true

module VectorMCP
  module Security
    module Strategies
      # Custom authentication strategy
      # Allows developers to implement their own authentication logic
      class Custom
        attr_reader :handler

        # Initialize with a custom authentication handler
        # @param handler [Proc] a block that takes a request and returns user info or false
        def initialize(&handler)
          raise ArgumentError, "Custom authentication strategy requires a block" unless handler

          @handler = handler
        end

        # Authenticate a request using the custom handler.
        # If the handler returns a Hash with a :user key, the value is extracted
        # so that AuthManager receives the user data directly.
        # @param request [Hash] the request object
        # @return [Object, nil, false] user data or false if authentication failed.
        #   A return of nil (from { user: nil }) signals "authenticated, no user object."
        def authenticate(request)
          result = @handler.call(request)
          return false unless result && result != false

          return result unless result.is_a?(Hash) && result.key?(:user)

          result[:user]
        rescue StandardError, NoMemoryError
          false
        end

        # Check if handler is configured
        # @return [Boolean] true if handler is present
        def configured?
          !@handler.nil?
        end
      end
    end
  end
end
