# frozen_string_literal: true

# Middleware framework for VectorMCP
# Provides pluggable hooks around MCP operations
require_relative "errors"
require_relative "middleware/context"
require_relative "middleware/hook"
require_relative "middleware/manager"
require_relative "middleware/base"

module VectorMCP
  # Middleware system for pluggable hooks around MCP operations
  # Allows developers to add custom behavior without modifying core code
  module Middleware
    # Hook types available in the system
    HOOK_TYPES = %w[
      before_tool_call after_tool_call on_tool_error
      before_resource_read after_resource_read on_resource_error
      before_prompt_get after_prompt_get on_prompt_error
      before_sampling_request after_sampling_response on_sampling_error
      before_request after_response on_transport_error
      before_auth after_auth on_auth_error
    ].freeze

    # Error raised when invalid hook type is specified
    class InvalidHookTypeError < VectorMCP::Error
      def initialize(hook_type)
        super("Invalid hook type: #{hook_type}. Valid types: #{HOOK_TYPES.join(", ")}")
      end
    end

    # Error raised when middleware execution fails
    class MiddlewareError < VectorMCP::Error
      attr_reader :original_error, :middleware_class

      def initialize(message, original_error: nil, middleware_class: nil)
        super(message)
        @original_error = original_error
        @middleware_class = middleware_class
      end
    end
  end
end
