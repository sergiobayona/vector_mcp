# frozen_string_literal: true

require "set"

module VectorMCP
  module Logging
    module Filters
      class Component
        def initialize(allowed_components = nil, blocked_components = nil)
          @allowed_components = normalize_components(allowed_components)
          @blocked_components = normalize_components(blocked_components)
        end

        def accept?(log_entry)
          return false if blocked?(log_entry.component)
          return true if @allowed_components.nil?

          allowed?(log_entry.component)
        end

        def allow_component(component)
          @allowed_components ||= Set.new
          @allowed_components.add(component.to_s)
        end

        def block_component(component)
          @blocked_components ||= Set.new
          @blocked_components.add(component.to_s)
        end

        def remove_component_filter(component)
          @allowed_components&.delete(component.to_s)
          @blocked_components&.delete(component.to_s)
        end

        private

        def allowed?(component)
          return true if @allowed_components.nil?

          @allowed_components.include?(component) ||
            @allowed_components.any? { |pattern| component.start_with?(pattern) }
        end

        def blocked?(component)
          return false if @blocked_components.nil?

          @blocked_components.include?(component) ||
            @blocked_components.any? { |pattern| component.start_with?(pattern) }
        end

        def normalize_components(components)
          case components
          when nil
            nil
          when String
            Set.new([components])
          when Array
            Set.new(components.map(&:to_s))
          when Set
            components
          else
            Set.new([components.to_s])
          end
        end
      end
    end
  end
end
