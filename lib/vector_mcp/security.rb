# frozen_string_literal: true

# Security namespace for VectorMCP
# Contains authentication, authorization, and security middleware components

require_relative "security/auth_manager"
require_relative "security/authorization"
require_relative "security/middleware"
require_relative "security/session_context"
require_relative "security/strategies/api_key"
require_relative "security/strategies/jwt_token"
require_relative "security/strategies/custom"

module VectorMCP
  # Security components for VectorMCP servers
  # Provides opt-in authentication and authorization
  module Security
    # Get default authentication manager
    # @return [AuthManager] a new authentication manager instance
    def self.auth_manager
      AuthManager.new
    end

    # Get default authorization manager
    # @return [Authorization] a new authorization manager instance
    def self.authorization
      Authorization.new
    end

    # Create security middleware with default components
    # @param auth_manager [AuthManager] optional custom auth manager
    # @param authorization [Authorization] optional custom authorization
    # @return [Middleware] configured security middleware
    def self.middleware(auth_manager: nil, authorization: nil)
      auth_manager ||= self.auth_manager
      authorization ||= self.authorization
      Middleware.new(auth_manager, authorization)
    end

    # Check if JWT support is available
    # @return [Boolean] true if JWT gem is loaded
    def self.jwt_available?
      Strategies::JwtToken.available?
    end
  end
end
