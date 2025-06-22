# frozen_string_literal: true

module VectorMCP
  module Security
    # Security middleware for request authentication and authorization
    # Integrates with transport layers to provide security controls
    class Middleware
      attr_reader :auth_manager, :authorization

      # Initialize middleware with auth components
      # @param auth_manager [AuthManager] the authentication manager
      # @param authorization [Authorization] the authorization manager
      def initialize(auth_manager, authorization)
        @auth_manager = auth_manager
        @authorization = authorization
      end

      # Authenticate a request and return session context
      # @param request [Hash] the request object
      # @param strategy [Symbol] optional authentication strategy override
      # @return [SessionContext] the session context for the request
      def authenticate_request(request, strategy: nil)
        auth_result = @auth_manager.authenticate(request, strategy: strategy)
        SessionContext.from_auth_result(auth_result)
      end

      # Check if a session is authorized for an action on a resource
      # @param session_context [SessionContext] the session context
      # @param action [Symbol] the action being attempted
      # @param resource [Object] the resource being accessed
      # @return [Boolean] true if authorized
      def authorize_action(session_context, action, resource)
        # Always allow if authorization is disabled
        return true unless @authorization.required?

        # Check authorization policy
        @authorization.authorize(session_context.user, action, resource)
      end

      # Process a request through the complete security pipeline
      # @param request [Hash] the request object
      # @param action [Symbol] the action being attempted
      # @param resource [Object] the resource being accessed
      # @return [Hash] result with session_context and authorization status
      def process_request(request, action: :access, resource: nil)
        # Step 1: Authenticate the request
        session_context = authenticate_request(request)

        # Step 2: Check if authentication is required but failed
        if @auth_manager.required? && !session_context.authenticated?
          return {
            success: false,
            error: "Authentication required",
            error_code: "AUTHENTICATION_REQUIRED",
            session_context: session_context
          }
        end

        # Step 3: Check authorization if resource is provided
        if resource && !authorize_action(session_context, action, resource)
          return {
            success: false,
            error: "Access denied",
            error_code: "AUTHORIZATION_FAILED",
            session_context: session_context
          }
        end

        # Step 4: Success
        {
          success: true,
          session_context: session_context
        }
      end

      # Create a request object from different transport formats
      # @param transport_request [Object] the transport-specific request
      # @return [Hash] normalized request object
      def normalize_request(transport_request)
        case transport_request
        when Hash
          # Check if it's a Rack environment (has REQUEST_METHOD key)
          if transport_request.key?("REQUEST_METHOD")
            extract_from_rack_env(transport_request)
          else
            # Already normalized
            transport_request
          end
        else
          # Extract from transport-specific request (e.g., custom objects)
          extract_request_data(transport_request)
        end
      end

      # Check if security is enabled
      # @return [Boolean] true if any security features are enabled
      def security_enabled?
        @auth_manager.required? || @authorization.required?
      end

      # Get security status for debugging/monitoring
      # @return [Hash] current security configuration status
      def security_status
        {
          authentication: {
            enabled: @auth_manager.required?,
            strategies: @auth_manager.available_strategies,
            default_strategy: @auth_manager.default_strategy
          },
          authorization: {
            enabled: @authorization.required?,
            policy_types: @authorization.policy_types
          }
        }
      end

      private

      # Extract request data from transport-specific formats
      # @param transport_request [Object] the transport request
      # @return [Hash] extracted request data
      def extract_request_data(transport_request)
        # Handle Rack environment (for SSE transport)
        if transport_request.respond_to?(:[]) && transport_request["REQUEST_METHOD"]
          extract_from_rack_env(transport_request)
        else
          # Default fallback
          { headers: {}, params: {} }
        end
      end

      # Extract data from Rack environment
      # @param env [Hash] the Rack environment
      # @return [Hash] extracted request data
      def extract_from_rack_env(env)
        # Extract headers (HTTP_ prefixed in Rack env)
        headers = {}
        env.each do |key, value|
          next unless key.start_with?("HTTP_")

          # Convert HTTP_X_API_KEY to X-API-Key format
          header_name = key[5..].split("_").map do |part|
            case part.upcase
            when "API" then "API" # Keep API in all caps
            else part.capitalize
            end
          end.join("-")
          headers[header_name] = value
        end

        # Add special headers
        headers["Authorization"] = env["HTTP_AUTHORIZATION"] if env["HTTP_AUTHORIZATION"]
        headers["Content-Type"] = env["CONTENT_TYPE"] if env["CONTENT_TYPE"]

        # Extract query parameters
        params = {}
        if env["QUERY_STRING"]
          require "uri"
          params = URI.decode_www_form(env["QUERY_STRING"]).to_h
        end

        {
          headers: headers,
          params: params,
          method: env["REQUEST_METHOD"],
          path: env["PATH_INFO"],
          rack_env: env
        }
      end
    end
  end
end
