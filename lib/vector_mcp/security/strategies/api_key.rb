# frozen_string_literal: true

module VectorMCP
  module Security
    module Strategies
      # API Key authentication strategy
      # Supports multiple key formats and storage methods
      class ApiKey
        attr_reader :valid_keys

        # Initialize with a list of valid API keys
        # @param keys [Array<String>] array of valid API keys
        def initialize(keys: [])
          @valid_keys = Set.new(keys.map(&:to_s))
        end

        # Add a valid API key
        # @param key [String] the API key to add
        def add_key(key)
          @valid_keys << key.to_s
        end

        # Remove an API key
        # @param key [String] the API key to remove
        def remove_key(key)
          @valid_keys.delete(key.to_s)
        end

        # Authenticate a request using API key
        # @param request [Hash] the request object
        # @return [Hash, false] user info hash or false if authentication failed
        def authenticate(request)
          api_key = extract_api_key(request)
          return false unless api_key&.length&.positive?

          if @valid_keys.include?(api_key)
            {
              api_key: api_key,
              strategy: "api_key",
              authenticated_at: Time.now
            }
          else
            false
          end
        end

        # Check if any keys are configured
        # @return [Boolean] true if keys are available
        def configured?
          !@valid_keys.empty?
        end

        # Get count of configured keys (for debugging)
        # @return [Integer] number of configured keys
        def key_count
          @valid_keys.size
        end

        private

        # Extract API key from various request formats
        # @param request [Hash] the request object
        # @return [String, nil] the extracted API key
        def extract_api_key(request)
          # Support multiple common formats
          headers = request[:headers] || request["headers"] || {}
          params = request[:params] || request["params"] || {}

          # 1. X-API-Key header (most common)
          api_key = headers["X-API-Key"] || headers["x-api-key"]
          return api_key if api_key

          # 2. Authorization header with Bearer token
          auth_header = headers["Authorization"] || headers["authorization"]
          if auth_header&.start_with?("Bearer ")
            return auth_header[7..-1] # Remove 'Bearer ' prefix
          end

          # 3. Authorization header with API-Key scheme
          if auth_header&.start_with?("API-Key ")
            return auth_header[8..-1] # Remove 'API-Key ' prefix
          end

          # 4. Query parameter (less secure, but supported)
          params["api_key"] || params["apikey"]
        end
      end
    end
  end
end
