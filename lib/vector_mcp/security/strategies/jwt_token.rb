# frozen_string_literal: true

begin
  require "jwt"
rescue LoadError
  # JWT gem is optional - will raise error when trying to use JWT strategy
end

module VectorMCP
  module Security
    module Strategies
      # JWT Token authentication strategy
      # Provides stateless authentication using JSON Web Tokens
      class JwtToken
        attr_reader :secret, :algorithm, :options

        # Initialize JWT strategy
        # @param secret [String] the secret key for JWT verification
        # @param algorithm [String] the JWT algorithm (default: HS256)
        # @param options [Hash] additional JWT verification options
        def initialize(secret:, algorithm: "HS256", **options)
          raise LoadError, "JWT gem is required for JWT authentication strategy" unless defined?(JWT)

          @secret = secret
          @algorithm = algorithm
          @options = {
            algorithm: @algorithm,
            verify_expiration: true,
            verify_iat: true,
            verify_iss: false,
            verify_aud: false
          }.merge(options)
        end

        # Authenticate a request using JWT token
        # @param request [Hash] the request object
        # @return [Hash, false] decoded JWT payload or false if authentication failed
        def authenticate(request)
          token = extract_token(request)
          return false unless token

          begin
            decoded = JWT.decode(token, @secret, true, @options)
            payload = decoded[0] # First element is the payload
            headers = decoded[1] # Second element is the headers

            # Return user info from JWT payload
            {
              **payload,
              strategy: "jwt",
              authenticated_at: Time.now,
              jwt_headers: headers
            }
          rescue JWT::ExpiredSignature, JWT::InvalidIssuerError, JWT::InvalidAudienceError,
                 JWT::DecodeError, StandardError
            false # Token validation failed
          end
        end

        # Generate a JWT token (utility method for testing/development)
        # @param payload [Hash] the payload to encode
        # @param expires_in [Integer] expiration time in seconds from now
        # @return [String] the generated JWT token
        def generate_token(payload, expires_in: 3600)
          exp_payload = payload.merge(
            exp: Time.now.to_i + expires_in,
            iat: Time.now.to_i
          )
          JWT.encode(exp_payload, @secret, @algorithm)
        end

        # Check if JWT gem is available
        # @return [Boolean] true if JWT gem is loaded
        def self.available?
          defined?(JWT)
        end

        private

        # Extract JWT token from request
        # @param request [Hash] the request object
        # @return [String, nil] the extracted token
        def extract_token(request)
          headers = request[:headers] || request["headers"] || {}
          params = request[:params] || request["params"] || {}

          extract_from_auth_header(headers) ||
            extract_from_jwt_header(headers) ||
            extract_from_params(params)
        end

        # Extract token from Authorization header
        # @param headers [Hash] request headers
        # @return [String, nil] the token if found
        def extract_from_auth_header(headers)
          auth_header = headers["Authorization"] || headers["authorization"]
          return nil unless auth_header&.start_with?("Bearer ")

          auth_header[7..] # Remove 'Bearer ' prefix
        end

        # Extract token from custom JWT header
        # @param headers [Hash] request headers
        # @return [String, nil] the token if found
        def extract_from_jwt_header(headers)
          headers["X-JWT-Token"] || headers["x-jwt-token"]
        end

        # Extract token from query parameters
        # @param params [Hash] request parameters
        # @return [String, nil] the token if found
        def extract_from_params(params)
          params["jwt_token"] || params["token"]
        end
      end
    end
  end
end
