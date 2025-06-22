# frozen_string_literal: true

require "logger"

module VectorMCP
  module Logging
    class Core
      attr_reader :configuration, :components, :outputs

      def initialize(configuration = nil)
        @configuration = configuration || Configuration.new
        @components = {}
        @outputs = []
        @mutex = Mutex.new
        @legacy_logger = nil

        setup_default_output
      end

      def logger_for(component_name)
        @mutex.synchronize do
          @components[component_name] ||= Component.new(
            component_name,
            self,
            @configuration.component_config(component_name)
          )
        end
      end

      def legacy_logger
        @legacy_logger ||= LegacyAdapter.new(self)
      end

      def log(level, component, message, context = {})
        return unless should_log?(level, component)

        log_entry = Logging::LogEntry.new(
          timestamp: Time.now,
          level: level,
          component: component,
          message: message,
          context: context,
          thread_id: Thread.current.object_id
        )

        @outputs.each do |output|
          output.write(log_entry)
        rescue StandardError => e
          warn "Failed to write to output #{output.class}: #{e.message}"
        end
      end

      def add_output(output)
        @mutex.synchronize do
          @outputs << output unless @outputs.include?(output)
        end
      end

      def remove_output(output)
        @mutex.synchronize do
          @outputs.delete(output)
        end
      end

      def configure(&)
        @configuration.configure(&)
        reconfigure_outputs
      end

      def shutdown
        @outputs.each(&:close)
        @outputs.clear
      end

      private

      def should_log?(level, component)
        min_level = @configuration.level_for(component)
        level >= min_level
      end

      def setup_default_output
        console_output = Outputs::Console.new(@configuration.console_config)
        add_output(console_output)
      end

      def reconfigure_outputs
        @outputs.each(&:reconfigure)
      end
    end


    class LegacyAdapter
      def initialize(core)
        @core = core
        @component = "legacy"
        @progname = "VectorMCP"
      end

      def debug(message = nil, &)
        log_with_block(Logging::LEVELS[:DEBUG], message, &)
      end

      def info(message = nil, &)
        log_with_block(Logging::LEVELS[:INFO], message, &)
      end

      def warn(message = nil, &)
        log_with_block(Logging::LEVELS[:WARN], message, &)
      end

      def error(message = nil, &)
        log_with_block(Logging::LEVELS[:ERROR], message, &)
      end

      def fatal(message = nil, &)
        log_with_block(Logging::LEVELS[:FATAL], message, &)
      end

      def level
        @core.configuration.level_for(@component)
      end

      def level=(new_level)
        @core.configuration.set_component_level(@component, new_level)
      end

      def progname
        @progname
      end

      def progname=(name)
        @progname = name
      end

      def add(severity, message = nil, progname = nil, &block)
        actual_message = message || block&.call || progname
        @core.log(severity, @component, actual_message)
      end

      # For backward compatibility with Logger interface checks
      def is_a?(klass)
        return true if klass == Logger
        super
      end

      def kind_of?(klass)
        return true if klass == Logger
        super
      end

      # Simulate Logger's logdev for compatibility
      def instance_variable_get(var_name)
        if var_name == :@logdev
          # Return a mock object that simulates Logger's logdev
          MockLogdev.new
        else
          super
        end
      end

      private

      def log_with_block(level, message, &block)
        if block_given?
          return unless @core.configuration.level_for(@component) <= level

          message = block.call
        end
        @core.log(level, @component, message)
      end
    end

    class MockLogdev
      def dev
        $stderr
      end
    end
  end
end
