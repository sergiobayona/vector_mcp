# frozen_string_literal: true

module VectorMCP
  module Logging
    module Filters
      class Level
        def initialize(min_level)
          @min_level = min_level.is_a?(Integer) ? min_level : Logging.level_value(min_level)
        end

        def accept?(log_entry)
          log_entry.level >= @min_level
        end

        def min_level=(new_level)
          @min_level = new_level.is_a?(Integer) ? new_level : Logging.level_value(new_level)
        end

        attr_reader :min_level
      end
    end
  end
end
