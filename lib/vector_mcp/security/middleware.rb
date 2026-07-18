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
    end
  end
end
