# frozen_string_literal: true

require "openssl"

module VectorMCP
  module Security
    module Strategies
      # API Key authentication strategy
      # Supports multiple key formats and storage methods
      class ApiKey
        attr_reader :valid_keys

        # Initialize with a list of valid API keys
        # @param keys [Array<String>] array of valid API keys
        # @param allow_query_params [Boolean] whether to accept API keys from query parameters (default: false)
        def initialize(keys: [], allow_query_params: false)
          @valid_keys = Set.new(keys.map(&:to_s))
          @allow_query_params = allow_query_params
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

          if secure_key_match?(api_key)
            { api_key: api_key }
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

        # Constant-time comparison of API key against all valid keys.
        # Iterates all keys to prevent timing side-channels.
        # @param candidate [String] the API key to check
        # @return [Boolean] true if the candidate matches a valid key
        def secure_key_match?(candidate)
          matched = false
          @valid_keys.each do |valid_key|
            next unless candidate.bytesize == valid_key.bytesize

            matched = true if OpenSSL.fixed_length_secure_compare(candidate, valid_key)
          end
          matched
        end

        # Extract API key from various request formats
        # @param request [Hash] the request object
        # @return [String, nil] the extracted API key
        def extract_api_key(request)
          headers = normalize_headers(request)

          from_headers = extract_from_headers(headers)
          return from_headers if from_headers

          return nil unless @allow_query_params

          params = normalize_params(request)
          extract_from_params(params)
        end

        # Normalize headers to handle different formats
        # @param request [Hash] the request object
        # @return [Hash] normalized headers
        def normalize_headers(request)
          # Check if it's a Rack environment (has REQUEST_METHOD)
          if request["REQUEST_METHOD"]
            extract_headers_from_rack_env(request)
          else
            request[:headers] || request["headers"] || {}
          end
        end

        # Normalize params to handle different formats
        # @param request [Hash] the request object
        # @return [Hash] normalized params
        def normalize_params(request)
          # Check if it's a Rack environment (has REQUEST_METHOD)
          if request["REQUEST_METHOD"]
            extract_params_from_rack_env(request)
          else
            request[:params] || request["params"] || {}
          end
        end

        # Extract headers from Rack environment
        # @param env [Hash] the Rack environment
        # @return [Hash] normalized headers
        def extract_headers_from_rack_env(env)
          VectorMCP::Util.extract_headers_from_rack_env(env)
        end

        # Extract params from Rack environment
        # @param env [Hash] the Rack environment
        # @return [Hash] normalized params
        def extract_params_from_rack_env(env)
          VectorMCP::Util.extract_params_from_rack_env(env)
        end

        # Extract API key from headers
        # @param headers [Hash] request headers
        # @return [String, nil] the API key if found
        def extract_from_headers(headers)
          # 1. X-API-Key header (most common)
          api_key = headers["X-API-Key"] || headers["x-api-key"]
          return api_key if api_key

          # 2. Authorization header
          extract_from_auth_header(headers["Authorization"] || headers["authorization"])
        end

        # Extract API key from Authorization header
        # @param auth_header [String, nil] the authorization header value
        # @return [String, nil] the API key if found
        def extract_from_auth_header(auth_header)
          return nil unless auth_header

          # Bearer token format
          return auth_header[7..] if auth_header.start_with?("Bearer ")

          # API-Key scheme format
          return auth_header[8..] if auth_header.start_with?("API-Key ")

          nil
        end

        # Extract API key from query parameters
        # @param params [Hash] request parameters
        # @return [String, nil] the API key if found
        def extract_from_params(params)
          params["api_key"] || params["apikey"]
        end
      end
    end
  end
end
