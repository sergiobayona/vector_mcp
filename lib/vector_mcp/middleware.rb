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
    # Maps each hook type to the operation_type it matches. `nil` means the
    # hook is transport- or auth-level and matches any operation_type.
    # This is the single source of truth — HOOK_TYPES is derived from it.
    HOOK_OPERATION_TYPES = {
      "before_tool_call" => :tool_call,
      "after_tool_call" => :tool_call,
      "on_tool_error" => :tool_call,
      "before_resource_read" => :resource_read,
      "after_resource_read" => :resource_read,
      "on_resource_error" => :resource_read,
      "before_prompt_get" => :prompt_get,
      "after_prompt_get" => :prompt_get,
      "on_prompt_error" => :prompt_get,
      "before_sampling_request" => :sampling,
      "after_sampling_response" => :sampling,
      "on_sampling_error" => :sampling,
      "before_request" => nil,
      "after_response" => nil,
      "on_transport_error" => nil,
      "before_auth" => nil,
      "after_auth" => nil,
      "on_auth_error" => nil
    }.freeze

    # Hook types available in the system (derived from HOOK_OPERATION_TYPES)
    HOOK_TYPES = HOOK_OPERATION_TYPES.keys.freeze

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
