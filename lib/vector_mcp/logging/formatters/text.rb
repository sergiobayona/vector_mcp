# frozen_string_literal: true

require_relative "../constants"

module VectorMCP
  module Logging
    module Formatters
      class Text < Base
        COLORS = {
          TRACE: "\e[90m",    # gray
          DEBUG: "\e[36m",    # cyan
          INFO: "\e[32m",     # green
          WARN: "\e[33m",     # yellow
          ERROR: "\e[31m",    # red
          FATAL: "\e[35m",    # magenta
          SECURITY: "\e[1;31m" # bold red
        }.freeze

        RESET_COLOR = "\e[0m"

        def initialize(options = {})
          super
          @colorize = options.fetch(:colorize, true)
          @include_timestamp = options.fetch(:include_timestamp, true)
          @include_thread = options.fetch(:include_thread, false)
          @include_component = options.fetch(:include_component, true)
          @max_message_length = options.fetch(:max_message_length, Constants::DEFAULT_MAX_MESSAGE_LENGTH)
        end

        def format(log_entry)
          parts = []

          parts << format_timestamp_part(log_entry.timestamp) if @include_timestamp

          parts << format_level_part(log_entry.level_name)

          parts << format_component_part(log_entry.component) if @include_component

          parts << format_thread_part(log_entry.thread_id) if @include_thread

          message = truncate_message(log_entry.message, @max_message_length)
          context_str = format_context(log_entry.context)

          "#{parts.join(" ")} #{message}#{context_str}\n"
        end

        private

        def format_timestamp_part(timestamp)
          "[#{format_timestamp(timestamp)}]"
        end

        def format_level_part(level_name)
          level_str = format_level(level_name.to_s, Constants::DEFAULT_LEVEL_WIDTH)
          if @colorize && COLORS[level_name.to_sym]
            "#{COLORS[level_name.to_sym]}#{level_str}#{RESET_COLOR}"
          else
            level_str
          end
        end

        def format_component_part(component)
          format_component(component, Constants::DEFAULT_COMPONENT_WIDTH)
        end

        def format_thread_part(thread_id)
          "[#{thread_id}]"
        end
      end
    end
  end
end
