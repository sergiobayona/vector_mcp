# frozen_string_literal: true

require "concurrent-ruby"

module VectorMCP
  module Middleware
    # Central manager for middleware hooks and execution
    # Thread-safe registry and execution engine for all middleware
    class Manager
      def initialize
        @hooks = Concurrent::Map.new { |h, k| h[k] = Concurrent::Array.new }
        @logger = VectorMCP.logger_for("middleware.manager")
      end

      # Register a middleware for specific hook types
      # @param middleware_class [Class] Middleware class inheriting from Base
      # @param hooks [Array<String, Symbol>] Hook types to register for
      # @param priority [Integer] Execution priority (lower numbers execute first)
      # @param conditions [Hash] Conditions for when middleware should run
      # @example
      #   manager.register(MyMiddleware, [:before_tool_call, :after_tool_call])
      #   manager.register(AuthMiddleware, :before_request, priority: 10)
      def register(middleware_class, hooks, priority: Hook::DEFAULT_PRIORITY, conditions: {})
        Array(hooks).each do |hook_type|
          hook = Hook.new(middleware_class, hook_type, priority: priority, conditions: conditions)
          add_hook(hook)
        end

        @logger.debug("Registered middleware") do
          {
            middleware: middleware_class.name,
            hooks: Array(hooks),
            priority: priority
          }
        end
      end

      # Remove all hooks for a specific middleware class
      # @param middleware_class [Class] Middleware class to remove
      def unregister(middleware_class)
        removed_count = 0

        @hooks.each_value do |hook_array|
          removed_count += hook_array.delete_if { |hook| hook.middleware_class == middleware_class }.size
        end

        @logger.debug("Unregistered middleware") do
          {
            middleware: middleware_class.name,
            hooks_removed: removed_count
          }
        end
      end

      # Execute all hooks for a specific hook type with timing
      # @param hook_type [String, Symbol] Type of hook to execute
      # @param context [VectorMCP::Middleware::Context] Execution context
      # @return [VectorMCP::Middleware::Context] Modified context
      def execute_hooks(hook_type, context)
        hook_type_str = hook_type.to_s
        hooks = get_sorted_hooks(hook_type_str)

        return context if hooks.empty?

        execution_state = initialize_execution_state(hook_type_str, hooks, context)
        execute_hook_chain(hooks, context, execution_state)
        finalize_execution(context, execution_state)

        context
      end

      # Get statistics about registered middleware
      # @return [Hash] Statistics summary
      def stats
        hook_counts = {}
        total_hooks = 0

        @hooks.each do |hook_type, hook_array|
          count = hook_array.size
          hook_counts[hook_type] = count
          total_hooks += count
        end

        {
          total_hooks: total_hooks,
          hook_types: hook_counts.keys.sort,
          hooks_by_type: hook_counts
        }
      end

      # Clear all registered hooks (useful for testing)
      def clear!
        @hooks.clear
        @logger.debug("Cleared all middleware hooks")
      end

      private

      def add_hook(hook)
        hook_type = hook.hook_type
        hook_array = @hooks[hook_type]

        # Insert hook in sorted position by priority
        insertion_index = hook_array.find_index { |existing_hook| existing_hook.priority > hook.priority }
        if insertion_index
          hook_array.insert(insertion_index, hook)
        else
          hook_array << hook
        end
      end

      def get_sorted_hooks(hook_type)
        @hooks[hook_type].to_a
      end

      def initialize_execution_state(hook_type_str, hooks, _context)
        start_time = Time.now

        # Executing middleware hooks

        {
          hook_type: hook_type_str,
          start_time: start_time,
          executed_count: 0,
          total_hooks: hooks.size
        }
      end

      def execute_hook_chain(hooks, context, execution_state)
        hooks.each do |hook|
          break if context.skip_remaining_hooks

          hook.execute(context)
          execution_state[:executed_count] += 1
        rescue MiddlewareError => e
          handle_critical_error(e, execution_state[:hook_type], context)
          break
        rescue StandardError => e
          handle_standard_error(e, execution_state[:hook_type])
          # Continue with other hooks for non-critical errors
        end
      end

      def finalize_execution(context, execution_state)
        execution_time = Time.now - execution_state[:start_time]

        context.add_metadata(:middleware_timing, {
                               hook_type: execution_state[:hook_type],
                               execution_time: execution_time,
                               hooks_executed: execution_state[:executed_count],
                               hooks_total: execution_state[:total_hooks]
                             })

        # Completed middleware execution
      end

      def handle_critical_error(error, hook_type, context)
        @logger.error("Critical middleware error") do
          {
            middleware: error.middleware_class&.name,
            hook_type: hook_type,
            error: error.message
          }
        end

        context.error = error
      end

      def handle_standard_error(error, hook_type)
        @logger.error("Unexpected middleware error") do
          {
            hook_type: hook_type,
            error: error.message
          }
        end
      end
    end
  end
end
