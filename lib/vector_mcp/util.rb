# frozen_string_literal: true

require "json"
require "base64"
require "uri"

module VectorMCP
  # Utility functions for MCP operations
  module Util
    module_function

    # Helper to convert tool/resource results into MCP 'content' array
    def convert_to_mcp_content(input, mime_type: "text/plain")
      case input
      when String
        [{ type: "text", text: input, mimeType: mime_type }]
      when Hash
        if input[:type] || input["type"] # Already in content format
          [input.transform_keys(&:to_sym)]
        else
          # Treat as a rich content object
          [input.transform_keys(&:to_sym)]
        end
      when Array
        if input.all? { |item| item.is_a?(Hash) && (item[:type] || item["type"]) }
          # Already an array of content items
          input.map { |item| item.transform_keys(&:to_sym) }
        else
          # Convert each item to text
          input.map { |item| { type: "text", text: item.to_s, mimeType: mime_type } }
        end
      else
        # Convert to string for everything else
        [{ type: "text", text: input.to_s, mimeType: mime_type }]
      end
    end

    # Extract ID from invalid JSON string using regex
    # This is a best-effort attempt to extract an ID from a malformed JSON string
    # Used mainly for reporting errors on parse failures
    def extract_id_from_invalid_json(json_string)
      # Try to find id field with various formats: "id": 123, "id":"abc", "id": "abc", etc.
      if (match = json_string.match(/"id"\s*:\s*(?:"([^"]+)"|(\d+))/))
        match[1] || match[2] # Return the string or number match
      else
        nil
      end
    end
  end
end
