# frozen_string_literal: true

module VectorMCP
  module Middleware
    # Base class for all middleware implementations
    # Provides common functionality and hook method templates
    class Base
      # Initialize middleware with optional configuration
      # @param config [Hash] Configuration options
      def initialize(config = {})
        @config = config
        @logger = VectorMCP.logger_for("middleware.#{self.class.name.split("::").last.downcase}")
      end

      # Generic hook dispatcher - override specific hook methods instead
      # @param hook_type [String] Type of hook being executed
      # @param context [VectorMCP::Middleware::Context] Execution context
      def call(hook_type, context)
        # Generic middleware hook execution
      end

      # Tool operation hooks

      # Called before tool execution
      # @param context [VectorMCP::Middleware::Context] Execution context
      def before_tool_call(context)
        # Override in subclasses
      end

      # Called after successful tool execution
      # @param context [VectorMCP::Middleware::Context] Execution context with result
      def after_tool_call(context)
        # Override in subclasses
      end

      # Called when tool execution fails
      # @param context [VectorMCP::Middleware::Context] Execution context with error
      def on_tool_error(context)
        # Override in subclasses
      end

      # Resource operation hooks

      # Called before resource read
      # @param context [VectorMCP::Middleware::Context] Execution context
      def before_resource_read(context)
        # Override in subclasses
      end

      # Called after successful resource read
      # @param context [VectorMCP::Middleware::Context] Execution context with result
      def after_resource_read(context)
        # Override in subclasses
      end

      # Called when resource read fails
      # @param context [VectorMCP::Middleware::Context] Execution context with error
      def on_resource_error(context)
        # Override in subclasses
      end

      # Prompt operation hooks

      # Called before prompt get
      # @param context [VectorMCP::Middleware::Context] Execution context
      def before_prompt_get(context)
        # Override in subclasses
      end

      # Called after successful prompt get
      # @param context [VectorMCP::Middleware::Context] Execution context with result
      def after_prompt_get(context)
        # Override in subclasses
      end

      # Called when prompt get fails
      # @param context [VectorMCP::Middleware::Context] Execution context with error
      def on_prompt_error(context)
        # Override in subclasses
      end

      # Sampling operation hooks

      # Called before sampling request
      # @param context [VectorMCP::Middleware::Context] Execution context
      def before_sampling_request(context)
        # Override in subclasses
      end

      # Called after successful sampling response
      # @param context [VectorMCP::Middleware::Context] Execution context with result
      def after_sampling_response(context)
        # Override in subclasses
      end

      # Called when sampling fails
      # @param context [VectorMCP::Middleware::Context] Execution context with error
      def on_sampling_error(context)
        # Override in subclasses
      end

      # Transport operation hooks

      # Called before any request processing
      # @param context [VectorMCP::Middleware::Context] Execution context
      def before_request(context)
        # Override in subclasses
      end

      # Called after successful response
      # @param context [VectorMCP::Middleware::Context] Execution context with result
      def after_response(context)
        # Override in subclasses
      end

      # Called when transport error occurs
      # @param context [VectorMCP::Middleware::Context] Execution context with error
      def on_transport_error(context)
        # Override in subclasses
      end

      # Authentication hooks

      # Called before authentication
      # @param context [VectorMCP::Middleware::Context] Execution context
      def before_auth(context)
        # Override in subclasses
      end

      # Called after successful authentication
      # @param context [VectorMCP::Middleware::Context] Execution context with result
      def after_auth(context)
        # Override in subclasses
      end

      # Called when authentication fails
      # @param context [VectorMCP::Middleware::Context] Execution context with error
      def on_auth_error(context)
        # Override in subclasses
      end

      protected

      attr_reader :config, :logger

      # Helper method to modify request parameters (if mutable)
      # @param context [VectorMCP::Middleware::Context] Execution context
      # @param new_params [Hash] New parameters to set
      def modify_params(context, new_params)
        if context.respond_to?(:params=)
          context.params = new_params
        else
          @logger.warn("Cannot modify immutable params in context")
        end
      end

      # Helper method to modify response result
      # @param context [VectorMCP::Middleware::Context] Execution context
      # @param new_result [Object] New result to set
      def modify_result(context, new_result)
        context.result = new_result
      end

      # Helper method to skip remaining hooks in the chain
      # @param context [VectorMCP::Middleware::Context] Execution context
      def skip_remaining_hooks(context)
        context.skip_remaining_hooks = true
      end
    end
  end
end
