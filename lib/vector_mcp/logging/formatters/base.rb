# frozen_string_literal: true

require_relative "../constants"

module VectorMCP
  module Logging
    module Formatters
      class Base
        def initialize(options = {})
          @options = options
        end

        def format(log_entry)
          raise NotImplementedError, "Subclasses must implement #format"
        end

        protected

        def format_timestamp(timestamp)
          timestamp.strftime("%Y-%m-%d %H:%M:%S.%#{Constants::TIMESTAMP_PRECISION}N")
        end

        def format_level(level_name, width = Constants::DEFAULT_LEVEL_WIDTH)
          level_name.ljust(width)
        end

        def format_component(component, width = Constants::DEFAULT_COMPONENT_WIDTH)
          if component.length > width
            "#{component[0..(width - Constants::TRUNCATION_SUFFIX_LENGTH)]}..."
          else
            component.ljust(width)
          end
        end

        def format_context(context)
          return "" if context.empty?

          pairs = context.map do |key, value|
            "#{key}=#{value}"
          end
          " (#{pairs.join(", ")})"
        end

        def truncate_message(message, max_length = Constants::DEFAULT_MAX_MESSAGE_LENGTH)
          return message if message.length <= max_length

          "#{message[0..(max_length - Constants::TRUNCATION_SUFFIX_LENGTH)]}..."
        end
      end
    end
  end
end
