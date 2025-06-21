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
          headers = normalize_headers(request)
          params = normalize_params(request)

          extract_from_headers(headers) || extract_from_params(params)
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
          headers = {}
          env.each do |key, value|
            if key.start_with?("HTTP_")
              # Convert HTTP_X_API_KEY to X-API-Key format
              header_name = key[5..].split("_").map do |part|
                case part.upcase
                when "API" then "API"  # Keep API in all caps
                else part.capitalize
                end
              end.join("-")
              headers[header_name] = value
            end
          end

          # Add special headers
          headers["Authorization"] = env["HTTP_AUTHORIZATION"] if env["HTTP_AUTHORIZATION"]
          headers["Content-Type"] = env["CONTENT_TYPE"] if env["CONTENT_TYPE"]
          headers
        end

        # Extract params from Rack environment
        # @param env [Hash] the Rack environment  
        # @return [Hash] normalized params
        def extract_params_from_rack_env(env)
          params = {}
          if env["QUERY_STRING"]
            require "uri"
            params = URI.decode_www_form(env["QUERY_STRING"]).to_h
          end
          params
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
