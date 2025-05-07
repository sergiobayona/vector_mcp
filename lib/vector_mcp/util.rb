# frozen_string_literal: true

require "json"
require "uri"

module VectorMCP
  # Provides utility functions for VectorMCP operations, such as data conversion
  # and parsing.
  module Util
    module_function

    # Converts a given Ruby object into an array of MCP content item(s).
    # This is the primary public method for content conversion.
    #
    # @param input [Object] The Ruby object to convert.
    #   Can be a String, Hash, Array, or other basic types.
    # @param mime_type [String] The default MIME type to use for textual content
    #   if not automatically determined (e.g., for JSON from a Hash).
    # @return [Array<Hash>] An array of MCP content item hashes.
    #   Each hash typically has `:type`, `:text`, and `:mimeType` keys.
    def convert_to_mcp_content(input, mime_type: "text/plain")
      return string_content(input, mime_type) if input.is_a?(String)
      return hash_content(input)             if input.is_a?(Hash)
      return array_content(input, mime_type) if input.is_a?(Array)

      fallback_content(input, mime_type)
    end

    # --- Conversion helpers (exposed as module functions) ---

    # Converts a String into an MCP text content item.
    # @param str [String] The string to convert.
    # @param mime_type [String] The MIME type for the content.
    # @return [Array<Hash>] MCP content array with one text item.
    def string_content(str, mime_type)
      [{ type: "text", text: str, mimeType: mime_type }]
    end

    # Converts a Hash into an MCP content item.
    # If the hash appears to be a pre-formatted MCP content item, it's used directly.
    # Otherwise, it's converted to a JSON string with `application/json` MIME type.
    # @param hash [Hash] The hash to convert.
    # @return [Array<Hash>] MCP content array.
    def hash_content(hash)
      if hash[:type] || hash["type"] # Already in content format
        [hash.transform_keys(&:to_sym)]
      else
        [{ type: "text", text: hash.to_json, mimeType: "application/json" }]
      end
    end

    # Converts an Array into MCP content items.
    # If all array elements are pre-formatted MCP content items, they are used directly.
    # Otherwise, each item in the array is recursively converted using {#convert_to_mcp_content}.
    # @param arr [Array] The array to convert.
    # @param mime_type [String] The default MIME type for child items if they need conversion.
    # @return [Array<Hash>] MCP content array.
    def array_content(arr, mime_type)
      if arr.all? { |item| item.is_a?(Hash) && (item[:type] || item["type"]) }
        arr.map { |item| item.transform_keys(&:to_sym) }
      else
        # Recursively convert each item, preserving the original mime_type intent for non-structured children.
        arr.flat_map { |item| convert_to_mcp_content(item, mime_type: mime_type) }
      end
    end

    # Fallback conversion for any other object type to an MCP text content item.
    # Converts the object to its string representation.
    # @param obj [Object] The object to convert.
    # @param mime_type [String] The MIME type for the content.
    # @return [Array<Hash>] MCP content array with one text item.
    def fallback_content(obj, mime_type)
      [{ type: "text", text: obj.to_s, mimeType: mime_type }]
    end

    module_function :string_content, :hash_content, :array_content, :fallback_content

    # Extracts an ID from a potentially malformed JSON string using regex.
    # This is a best-effort attempt, primarily for error reporting when full JSON parsing fails.
    # It looks for patterns like `"id": 123` or `"id": "abc"`.
    #
    # @param json_string [String] The (potentially invalid) JSON string.
    # @return [String, nil] The extracted ID as a string if found (numeric or string), otherwise nil.
    def extract_id_from_invalid_json(json_string)
      # Try to find id field with numeric value
      numeric_match = json_string.match(/"id"\s*:\s*(\d+)/)
      return numeric_match[1] if numeric_match

      # Try to find id field with string value, preserving escaped characters
      string_match = json_string.match(/"id"\s*:\s*"((?:\\.|[^"])*)"/)
      return string_match[1] if string_match

      nil
    end
  end
end
