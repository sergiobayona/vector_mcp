# frozen_string_literal: true

module VectorMCP
  module Logging
    class Component
      attr_reader :name, :core, :config

      def initialize(name, core, config = {})
        @name = name.to_s
        @core = core
        @config = config
        @context = {}
      end

      def with_context(context)
        old_context = @context
        @context = @context.merge(context)
        yield
      ensure
        @context = old_context
      end

      def add_context(context)
        @context = @context.merge(context)
      end

      def clear_context
        @context = {}
      end

      def trace(message = nil, context: {}, &block)
        log_with_block(Logging::LEVELS[:TRACE], message, context, &block)
      end

      def debug(message = nil, context: {}, &block)
        log_with_block(Logging::LEVELS[:DEBUG], message, context, &block)
      end

      def info(message = nil, context: {}, &block)
        log_with_block(Logging::LEVELS[:INFO], message, context, &block)
      end

      def warn(message = nil, context: {}, &block)
        log_with_block(Logging::LEVELS[:WARN], message, context, &block)
      end

      def error(message = nil, context: {}, &block)
        log_with_block(Logging::LEVELS[:ERROR], message, context, &block)
      end

      def fatal(message = nil, context: {}, &block)
        log_with_block(Logging::LEVELS[:FATAL], message, context, &block)
      end

      def security(message = nil, context: {}, &block)
        log_with_block(Logging::LEVELS[:SECURITY], message, context, &block)
      end

      def level
        @core.configuration.level_for(@name)
      end

      def level_enabled?(level)
        level >= self.level
      end

      def trace?
        level_enabled?(Logging::LEVELS[:TRACE])
      end

      def debug?
        level_enabled?(Logging::LEVELS[:DEBUG])
      end

      def info?
        level_enabled?(Logging::LEVELS[:INFO])
      end

      def warn?
        level_enabled?(Logging::LEVELS[:WARN])
      end

      def error?
        level_enabled?(Logging::LEVELS[:ERROR])
      end

      def fatal?
        level_enabled?(Logging::LEVELS[:FATAL])
      end

      def security?
        level_enabled?(Logging::LEVELS[:SECURITY])
      end

      def measure(message, context: {}, level: :info, &block)
        start_time = Time.now
        result = nil
        error = nil

        begin
          result = block.call
        rescue StandardError => e
          error = e
          raise
        ensure
          duration = Time.now - start_time
          measure_context = context.merge(
            duration_ms: (duration * 1000).round(2),
            success: error.nil?
          )
          measure_context[:error] = error.class.name if error

          send(level, "#{message} completed", context: measure_context)
        end

        result
      end

      private

      def log_with_block(level, message, context, &block)
        return unless level_enabled?(level)

        message = block.call if block_given?

        full_context = @context.merge(context)
        @core.log(level, @name, message, full_context)
      end
    end
  end
end
