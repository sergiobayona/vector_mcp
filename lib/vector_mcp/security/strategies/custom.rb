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

        # Authenticate a request using the custom handler
        # @param request [Hash] the request object
        # @return [Object, false] result from custom handler or false if authentication failed
        def authenticate(request)
          result = @handler.call(request)

          # Ensure result includes strategy info if it's successful
          if result && result != false
            format_successful_result(result)
          else
            false
          end
        rescue NoMemoryError, StandardError
          # Log error but return false for security
          false
        end

        # Check if handler is configured
        # @return [Boolean] true if handler is present
        def configured?
          !@handler.nil?
        end

        private

        # Format successful authentication result with strategy metadata
        # @param result [Object] the result from the custom handler
        # @return [Object] formatted result with strategy metadata
        def format_successful_result(result)
          case result
          when Hash
            # If result has a :user key, extract it and use as main user data
            if result.key?(:user)
              user_data = result[:user]
              # For nil user, return a marker that will become nil in session context
              return :authenticated_nil_user if user_data.nil?

              user_data
            else
              result.merge(strategy: "custom", authenticated_at: Time.now)
            end
          else
            {
              user: result,
              strategy: "custom",
              authenticated_at: Time.now
            }
          end
        end
      end
    end
  end
end
