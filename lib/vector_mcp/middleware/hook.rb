# frozen_string_literal: true

module VectorMCP
  module Middleware
    # Represents a single middleware hook with priority and execution logic
    class Hook
      attr_reader :middleware_class, :hook_type, :priority, :conditions

      # Default priority for middleware (lower numbers execute first)
      DEFAULT_PRIORITY = 100

      # @param middleware_class [Class] The middleware class to execute
      # @param hook_type [String, Symbol] Type of hook (before_tool_call, etc.)
      # @param priority [Integer] Execution priority (lower numbers execute first)
      # @param conditions [Hash] Conditions for when this hook should run
      def initialize(middleware_class, hook_type, priority: DEFAULT_PRIORITY, conditions: {})
        @middleware_class = middleware_class
        @hook_type = hook_type.to_s
        @priority = priority
        @conditions = conditions

        validate_hook_type!
        validate_middleware_class!
      end

      # Execute this hook with the given context
      # @param context [VectorMCP::Middleware::Context] Execution context
      # @return [void]
      def execute(context)
        return unless should_execute?(context)

        # Create middleware instance and execute hook
        middleware_instance = create_middleware_instance(context)
        execute_hook_method(middleware_instance, context)
      rescue StandardError => e
        handle_hook_error(e, context)
      end

      # Check if this hook should execute for the given context
      # @param context [VectorMCP::Middleware::Context] Execution context
      # @return [Boolean] true if hook should execute
      def should_execute?(context)
        return false if context.skip_remaining_hooks

        # Check operation type match
        return false unless matches_operation_type?(context)

        # Check custom conditions
        @conditions.all? { |key, value| condition_matches?(key, value, context) }
      end

      # Compare hooks for sorting by priority
      # @param other [Hook] Other hook to compare
      # @return [Integer] Comparison result
      def <=>(other)
        @priority <=> other.priority
      end

      private

      def validate_hook_type!
        return if HOOK_TYPES.include?(@hook_type)

        raise InvalidHookTypeError, @hook_type
      end

      def validate_middleware_class!
        raise ArgumentError, "middleware_class must be a Class, got #{@middleware_class.class}" unless @middleware_class.is_a?(Class)

        return if @middleware_class < VectorMCP::Middleware::Base

        raise ArgumentError, "middleware_class must inherit from VectorMCP::Middleware::Base"
      end

      def matches_operation_type?(context)
        operation_prefix = @hook_type.split("_")[1..].join("_")

        return true if transport_or_auth_hook?(operation_prefix)

        operation_matches?(operation_prefix, context.operation_type)
      end

      def condition_matches?(key, value, context)
        case key
        when :only_operations, :except_operations
          operation_condition_matches?(key, value, context)
        when :only_users, :except_users
          user_condition_matches?(key, value, context)
        else
          true # Unknown conditions are ignored
        end
      end

      def transport_or_auth_hook?(operation_prefix)
        %w[request response transport_error auth auth_error].include?(operation_prefix)
      end

      def operation_matches?(operation_prefix, operation_type)
        case operation_prefix
        when "tool_call", "tool_error"
          operation_type == :tool_call
        when "resource_read", "resource_error"
          operation_type == :resource_read
        when "prompt_get", "prompt_error"
          operation_type == :prompt_get
        when "sampling_request", "sampling_response", "sampling_error"
          operation_type == :sampling
        else
          true
        end
      end

      def operation_condition_matches?(key, value, context)
        included = Array(value).include?(context.operation_name)
        key == :only_operations ? included : !included
      end

      def user_condition_matches?(key, value, context)
        user_id = context.user&.[](:user_id) || context.user&.[]("user_id")
        included = Array(value).include?(user_id)
        key == :only_users ? included : !included
      end

      def create_middleware_instance(_context)
        if @middleware_class.respond_to?(:new)
          @middleware_class.new
        else
          @middleware_class
        end
      end

      def execute_hook_method(middleware_instance, context)
        method_name = @hook_type

        if middleware_instance.respond_to?(method_name)
          middleware_instance.public_send(method_name, context)
        elsif middleware_instance.respond_to?(:call)
          # Fallback to generic call method
          middleware_instance.call(@hook_type, context)
        else
          raise MiddlewareError,
                "Middleware #{@middleware_class} does not respond to #{method_name} or call",
                middleware_class: @middleware_class
        end
      end

      def handle_hook_error(error, context)
        # Log the error but don't break the chain unless it's critical
        logger = VectorMCP.logger_for("middleware")
        logger.error("Middleware hook failed") do
          {
            middleware: @middleware_class.name,
            hook_type: @hook_type,
            operation: context.operation_name,
            error: error.message
          }
        end

        # Re-raise if it's a critical error that should stop execution
        return unless error.is_a?(VectorMCP::Error) || @conditions[:critical] == true

        raise MiddlewareError,
              "Critical middleware failure in #{@middleware_class}",
              original_error: error,
              middleware_class: @middleware_class
      end
    end
  end
end
