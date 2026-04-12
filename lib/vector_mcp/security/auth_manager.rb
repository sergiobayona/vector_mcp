# frozen_string_literal: true

require_relative "auth_result"

module VectorMCP
  module Security
    # Manages authentication strategies for VectorMCP servers
    # Provides opt-in authentication with zero configuration by default
    class AuthManager
      attr_reader :strategies, :enabled, :default_strategy

      def initialize
        @strategies = {}
        @enabled = false
        @default_strategy = nil
      end

      # Enable authentication with optional default strategy
      # @param default_strategy [Symbol] the default authentication strategy to use
      def enable!(default_strategy: :api_key)
        @enabled = true
        @default_strategy = default_strategy
      end

      # Disable authentication (return to pass-through mode)
      def disable!
        @enabled = false
        @default_strategy = nil
      end

      # Add an authentication strategy
      # @param name [Symbol] the strategy name
      # @param strategy [Object] the strategy instance
      def add_strategy(name, strategy)
        @strategies[name] = strategy
      end

      # Remove an authentication strategy
      # @param name [Symbol] the strategy name to remove
      def remove_strategy(name)
        @strategies.delete(name)
      end

      # Authenticate a request using the specified or default strategy
      # @param request [Hash] the request object containing headers, params, etc.
      # @param strategy [Symbol] optional strategy override
      # @return [AuthResult] the authentication outcome
      def authenticate(request, strategy: nil)
        return AuthResult.passthrough unless @enabled

        strategy_name = strategy || @default_strategy
        auth_strategy = @strategies[strategy_name]
        return AuthResult.failure unless auth_strategy

        result = auth_strategy.authenticate(request)
        if result == false
          AuthResult.failure
        else
          AuthResult.success(user: result, strategy: strategy_name.to_s)
        end
      rescue StandardError
        AuthResult.failure
      end

      # Check if authentication is required
      # @return [Boolean] true if authentication is enabled
      def required?
        @enabled
      end

      # Get list of available strategies
      # @return [Array<Symbol>] array of strategy names
      def available_strategies
        @strategies.keys
      end
    end
  end
end
