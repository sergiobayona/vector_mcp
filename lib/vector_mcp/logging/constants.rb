# frozen_string_literal: true

module VectorMCP
  module Logging
    module Constants
      # JSON serialization limits
      MAX_SERIALIZATION_DEPTH = 5
      MAX_ARRAY_SERIALIZATION_DEPTH = 3
      MAX_ARRAY_ELEMENTS_TO_SERIALIZE = 10

      # Text formatting limits
      DEFAULT_MAX_MESSAGE_LENGTH = 1000
      DEFAULT_COMPONENT_WIDTH = 20
      DEFAULT_LEVEL_WIDTH = 8
      TRUNCATION_SUFFIX_LENGTH = 4 # for "..."

      # ISO timestamp precision
      TIMESTAMP_PRECISION = 3 # milliseconds
    end
  end
end
