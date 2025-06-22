# frozen_string_literal: true

require_relative "logging/core"
require_relative "logging/configuration"
require_relative "logging/component"
require_relative "logging/formatters/base"
require_relative "logging/formatters/text"
require_relative "logging/formatters/json"
require_relative "logging/outputs/base"
require_relative "logging/outputs/console"
require_relative "logging/outputs/file"
require_relative "logging/filters/level"
require_relative "logging/filters/component"

module VectorMCP
  module Logging
    class Error < StandardError; end
    class ConfigurationError < Error; end
    class FormatterError < Error; end
    class OutputError < Error; end

    LEVELS = {
      TRACE: 0,
      DEBUG: 1,
      INFO: 2,
      WARN: 3,
      ERROR: 4,
      FATAL: 5,
      SECURITY: 6
    }.freeze

    LEVEL_NAMES = LEVELS.invert.freeze

    def self.level_name(level)
      (LEVEL_NAMES[level] || "UNKNOWN").to_s
    end

    def self.level_value(name)
      LEVELS[name.to_s.upcase.to_sym] || LEVELS[:INFO]
    end

    class LogEntry
      attr_reader :timestamp, :level, :component, :message, :context, :thread_id

      def initialize(timestamp:, level:, component:, message:, context:, thread_id:)
        @timestamp = timestamp
        @level = level
        @component = component
        @message = message
        @context = context || {}
        @thread_id = thread_id
      end

      def level_name
        Logging.level_name(@level)
      end

      def to_h
        {
          timestamp: @timestamp.iso8601(3),
          level: level_name,
          component: @component,
          message: @message,
          context: @context,
          thread_id: @thread_id
        }
      end
    end
  end
end
