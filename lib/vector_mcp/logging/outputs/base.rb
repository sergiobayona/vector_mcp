# frozen_string_literal: true

module VectorMCP
  module Logging
    module Outputs
      class Base
        attr_reader :formatter, :config

        def initialize(config = {})
          @config = config
          @formatter = create_formatter
          @closed = false
        end

        def write(log_entry)
          return if @closed

          formatted_message = @formatter.format(log_entry)
          write_formatted(formatted_message)
        rescue StandardError => e
          fallback_write("Logging output error: #{e.message}\n")
        end

        def close
          @closed = true
        end

        def closed?
          @closed
        end

        def reconfigure
          @formatter = create_formatter
        end

        protected

        def write_formatted(message)
          raise NotImplementedError, "Subclasses must implement #write_formatted"
        end

        def fallback_write(message)
          $stderr.write(message)
        end

        private

        def create_formatter
          format_type = @config[:format] || "text"
          formatter_options = @config.except(:format)

          case format_type.to_s.downcase
          when "json"
            Formatters::Json.new(formatter_options)
          when "text"
            Formatters::Text.new(formatter_options)
          else
            raise OutputError, "Unknown formatter type: #{format_type}"
          end
        end
      end
    end
  end
end
