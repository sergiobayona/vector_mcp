# frozen_string_literal: true

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
          timestamp.strftime("%Y-%m-%d %H:%M:%S.%3N")
        end

        def format_level(level_name, width = 8)
          level_name.ljust(width)
        end

        def format_component(component, width = 20)
          if component.length > width
            "#{component[0..(width - 4)]}..."
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

        def truncate_message(message, max_length = 1000)
          return message if message.length <= max_length

          "#{message[0..(max_length - 4)]}..."
        end
      end
    end
  end
end
