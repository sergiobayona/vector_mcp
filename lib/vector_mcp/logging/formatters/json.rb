# frozen_string_literal: true

require "json"

module VectorMCP
  module Logging
    module Formatters
      class Json < Base
        def initialize(options = {})
          super
          @pretty = options.fetch(:pretty, false)
          @include_thread = options.fetch(:include_thread, false)
        end

        def format(log_entry)
          data = {
            timestamp: log_entry.timestamp.iso8601(3),
            level: log_entry.level_name,
            component: log_entry.component,
            message: log_entry.message
          }

          data[:context] = log_entry.context unless log_entry.context.empty?
          data[:thread_id] = log_entry.thread_id if @include_thread

          if @pretty
            "#{JSON.pretty_generate(data)}\n"
          else
            "#{JSON.generate(data)}\n"
          end
        rescue JSON::GeneratorError, JSON::NestingError => e
          fallback_format(log_entry, e)
        end

        private

        def fallback_format(log_entry, error)
          safe_data = {
            timestamp: log_entry.timestamp.iso8601(3),
            level: log_entry.level_name,
            component: log_entry.component,
            message: "JSON serialization failed: #{error.message}",
            original_message: log_entry.message.to_s,
            context: sanitize_context(log_entry.context)
          }

          "#{JSON.generate(safe_data)}\n"
        end

        def sanitize_context(context, depth = 0)
          return "<max_depth_reached>" if depth > 5
          return {} unless context.is_a?(Hash)

          context.each_with_object({}) do |(key, value), sanitized|
            sanitized[key.to_s] = sanitize_value(value, depth + 1)
          end
        rescue StandardError
          { "<sanitization_error>" => true }
        end

        def sanitize_value(value, depth = 0)
          return "<max_depth_reached>" if depth > 5

          case value
          when String, Numeric, TrueClass, FalseClass, NilClass
            value
          when Array
            return "<complex_array>" if depth > 3

            value.first(10).map { |v| sanitize_value(v, depth + 1) }
          when Hash
            sanitize_context(value, depth)
          else
            value.to_s
          end
        rescue StandardError
          "<serialization_error>"
        end
      end
    end
  end
end
