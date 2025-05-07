# frozen_string_literal: true

require "json"
require "uri"

module VectorMCP
  # Utility functions for MCP operations
  module Util
    module_function

    # Public: Convert various Ruby values into the MCP `content` array format.
    # Splits responsibilities across small helpers to keep complexity low.
    def convert_to_mcp_content(input, mime_type: "text/plain")
      return string_content(input, mime_type) if input.is_a?(String)
      return hash_content(input)             if input.is_a?(Hash)
      return array_content(input, mime_type) if input.is_a?(Array)

      fallback_content(input, mime_type)
    end

    # --- Conversion helpers (module_function provides public access) ---

    def string_content(str, mime_type)
      [{ type: "text", text: str, mimeType: mime_type }]
    end

    def hash_content(hash)
      if hash[:type] || hash["type"]
        [hash.transform_keys(&:to_sym)]
      else
        [{ type: "text", text: hash.to_json, mimeType: "application/json" }]
      end
    end

    def array_content(arr, mime_type)
      if arr.all? { |item| item.is_a?(Hash) && (item[:type] || item["type"]) }
        arr.map { |item| item.transform_keys(&:to_sym) }
      else
        arr.flat_map { |item| convert_to_mcp_content(item, mime_type:) }
      end
    end

    def fallback_content(obj, mime_type)
      [{ type: "text", text: obj.to_s, mimeType: mime_type }]
    end

    module_function :string_content, :hash_content, :array_content, :fallback_content

    # Extract an ID from malformed JSON for error reporting purposes.
    # Returns the ID as a String, or nil when unavailable.
    def extract_id_from_invalid_json(json_string)
      numeric_match = json_string.match(/"id"\s*:\s*(\d+)/)
      return numeric_match[1] if numeric_match

      string_match = json_string.match(/"id"\s*:\s*"((?:\\.|[^"])*)"/)
      return string_match[1] if string_match

      nil
    end
  end
end
