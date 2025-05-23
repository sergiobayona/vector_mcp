# frozen_string_literal: true

require "json"
require "uri"

module VectorMCP
  # Provides utility functions for VectorMCP operations, such as data conversion
  # and parsing.
  module Util
    module_function

    # Converts a given Ruby object into an **array of MCP content items**.
    # This is the *primary* public helper for transforming arbitrary Ruby values
    # into the wire-format expected by the MCP spec.
    #
    # Keys present in each returned hash:
    # * **:type**      – `"text"` or `"image"`; automatic detection for binary data.
    # * **:text**      – UTF-8 encoded payload (for text content).
    # * **:data**      – Base64 encoded payload (for image content).
    # * **:mimeType**  – IANA media-type describing the content.
    # * **:uri**       – _Optional._  Added downstream (e.g., by {Handlers::Core.read_resource}).
    #
    # The method **never** returns `nil` and **always** returns at least one element.
    #
    # @param input [Object] The Ruby value to convert. Supported types are
    #   `String`, `Hash`, `Array`, or any object that responds to `#to_s`.
    # @param mime_type [String] The fallback MIME type for plain-text conversions
    #   (defaults to `"text/plain"`).
    # @return [Array<Hash>] A non-empty array whose hashes conform to the MCP
    #   `Content` schema.
    #
    # @example Simple string
    #   VectorMCP::Util.convert_to_mcp_content("Hello")
    #   # => [{type: "text", text: "Hello", mimeType: "text/plain"}]
    #
    # @example Complex object
    #   VectorMCP::Util.convert_to_mcp_content({foo: 1})
    #   # => [{type: "text", text: "{\"foo\":1}", mimeType: "application/json"}]
    #
    # @example Image file path
    #   VectorMCP::Util.convert_to_mcp_content("image.jpg")
    #   # => [{type: "image", data: "base64...", mimeType: "image/jpeg"}]
    def convert_to_mcp_content(input, mime_type: "text/plain")
      return string_content(input, mime_type) if input.is_a?(String)
      return hash_content(input)             if input.is_a?(Hash)
      return array_content(input, mime_type) if input.is_a?(Array)

      fallback_content(input, mime_type)
    end

    # --- Conversion helpers (exposed as module functions) ---

    # Converts a String into an MCP content item.
    # Intelligently detects if the string is binary image data, a file path to an image,
    # or regular text content.
    # @param str [String] The string to convert.
    # @param mime_type [String] The MIME type for the content.
    # @return [Array<Hash>] MCP content array with one item.
    def string_content(str, mime_type)
      # Check if this might be a file path to an image
      return file_path_to_image_content(str) if looks_like_image_file_path?(str)

      # Check if this is binary image data
      return binary_image_to_content(str) if binary_image_data?(str)

      # Default to text content
      [{ type: "text", text: str, mimeType: mime_type }]
    end

    # Converts a Hash into an MCP content item.
    # If the hash appears to be a pre-formatted MCP content item, it's used directly.
    # Otherwise, it's converted to a JSON string with `application/json` MIME type.
    # @param hash [Hash] The hash to convert.
    # @return [Array<Hash>] MCP content array.
    def hash_content(hash)
      if hash[:type] || hash["type"] # Already in content format
        normalized = hash.transform_keys(&:to_sym)

        # Validate and enhance image content if needed
        return [validate_and_enhance_image_content(normalized)] if normalized[:type] == "image"

        [normalized]
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
        arr.map do |item|
          normalized = item.transform_keys(&:to_sym)
          if normalized[:type] == "image"
            validate_and_enhance_image_content(normalized)
          else
            normalized
          end
        end
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

    private

    # Checks if a string looks like a file path to an image.
    # @param str [String] The string to check.
    # @return [Boolean] True if it looks like an image file path.
    def looks_like_image_file_path?(str)
      return false if str.nil? || str.empty? || str.length > 500

      # Check for common image extensions
      image_extensions = %w[.jpg .jpeg .png .gif .webp .bmp .tiff .tif .svg]
      has_image_extension = image_extensions.any? { |ext| str.downcase.end_with?(ext) }

      # Check if it looks like a file path (contains / or \ or ends with image extension)
      looks_like_path = str.include?("/") || str.include?("\\") || has_image_extension

      has_image_extension && looks_like_path
    end

    # Checks if a string contains binary image data.
    # @param str [String] The string to check.
    # @return [Boolean] True if it appears to be binary image data.
    def binary_image_data?(str)
      return false if str.nil? || str.empty?

      # Check encoding first
      encoding = str.encoding
      is_binary = encoding == Encoding::ASCII_8BIT || !str.valid_encoding?

      return false unless is_binary

      # Use ImageUtil to detect if it's actually image data
      require_relative "image_util"
      !VectorMCP::ImageUtil.detect_image_format(str).nil?
    rescue StandardError
      false
    end

    # Converts a file path string to image content.
    # @param file_path [String] Path to the image file.
    # @return [Array<Hash>] MCP content array with image content.
    def file_path_to_image_content(file_path)
      require_relative "image_util"

      begin
        image_content = VectorMCP::ImageUtil.file_to_mcp_image_content(file_path)
        [image_content]
      rescue ArgumentError => e
        # If image processing fails, fall back to text content with error message
        [{ type: "text", text: "Error loading image '#{file_path}': #{e.message}", mimeType: "text/plain" }]
      end
    end

    # Converts binary image data to MCP image content.
    # @param binary_data [String] Binary image data.
    # @return [Array<Hash>] MCP content array with image content.
    def binary_image_to_content(binary_data)
      require_relative "image_util"

      begin
        image_content = VectorMCP::ImageUtil.to_mcp_image_content(binary_data)
        [image_content]
      rescue ArgumentError
        # If image processing fails, fall back to text content
        [{ type: "text", text: binary_data.to_s, mimeType: "application/octet-stream" }]
      end
    end

    # Validates and enhances existing image content hash.
    # @param content [Hash] Existing image content hash.
    # @return [Hash] Validated and enhanced image content.
    def validate_and_enhance_image_content(content)
      # Ensure required fields are present
      raise ArgumentError, "Image content must have both :data and :mimeType fields" unless content[:data] && content[:mimeType]

      # Validate the base64 data if possible
      begin
        require_relative "image_util"
        VectorMCP::ImageUtil.decode_base64(content[:data])
      rescue ArgumentError => e
        raise ArgumentError, "Invalid base64 image data: #{e.message}"
      end

      content
    end

    module_function :looks_like_image_file_path?, :binary_image_data?,
                    :file_path_to_image_content, :binary_image_to_content,
                    :validate_and_enhance_image_content
  end
end
