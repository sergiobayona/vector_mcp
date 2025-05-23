# frozen_string_literal: true

require "base64"
require "stringio"

module VectorMCP
  # Provides comprehensive image handling utilities for VectorMCP operations,
  # including format detection, validation, encoding/decoding, and conversion
  # to MCP-compliant image content format.
  module ImageUtil
    module_function

    # Common image MIME types and their magic byte signatures
    IMAGE_SIGNATURES = {
      "image/jpeg" => [
        [0xFF, 0xD8, 0xFF].pack("C*"),
        [0xFF, 0xD8].pack("C*")
      ],
      "image/png" => [[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A].pack("C*")],
      "image/gif" => %w[
        GIF87a
        GIF89a
      ],
      "image/webp" => [
        "WEBP"
      ],
      "image/bmp" => [
        "BM"
      ],
      "image/tiff" => [
        "II*\0",
        "MM\0*"
      ]
    }.freeze

    # Maximum image size in bytes (default: 10MB)
    DEFAULT_MAX_SIZE = 10 * 1024 * 1024

    # Detects the MIME type of image data based on magic bytes.
    #
    # @param data [String] The binary image data.
    # @return [String, nil] The detected MIME type, or nil if not recognized.
    #
    # @example
    #   VectorMCP::ImageUtil.detect_image_format(File.binread("image.jpg"))
    #   # => "image/jpeg"
    def detect_image_format(data)
      return nil if data.nil? || data.empty?

      # Ensure we have binary data (dup to avoid modifying frozen strings)
      binary_data = data.dup.force_encoding(Encoding::ASCII_8BIT)

      IMAGE_SIGNATURES.each do |mime_type, signatures|
        signatures.each do |signature|
          case mime_type
          when "image/webp"
            # WebP files start with RIFF then have WEBP at offset 8
            return mime_type if binary_data.start_with?("RIFF") && binary_data[8, 4] == signature
          else
            return mime_type if binary_data.start_with?(signature)
          end
        end
      end

      nil
    end

    # Validates if the provided data is a valid image.
    #
    # @param data [String] The binary image data.
    # @param max_size [Integer] Maximum allowed size in bytes.
    # @param allowed_formats [Array<String>] Allowed MIME types.
    # @return [Hash] Validation result with :valid, :mime_type, and :errors keys.
    #
    # @example
    #   result = VectorMCP::ImageUtil.validate_image(image_data)
    #   if result[:valid]
    #     puts "Valid #{result[:mime_type]} image"
    #   else
    #     puts "Errors: #{result[:errors].join(', ')}"
    #   end
    def validate_image(data, max_size: DEFAULT_MAX_SIZE, allowed_formats: nil)
      errors = []

      if data.nil? || data.empty?
        errors << "Image data is empty"
        return { valid: false, mime_type: nil, errors: errors }
      end

      # Check file size
      errors << "Image size (#{data.bytesize} bytes) exceeds maximum allowed size (#{max_size} bytes)" if data.bytesize > max_size

      # Detect format
      mime_type = detect_image_format(data)
      if mime_type.nil?
        errors << "Unrecognized or invalid image format"
        return { valid: false, mime_type: nil, errors: errors }
      end

      # Check allowed formats
      if allowed_formats && !allowed_formats.include?(mime_type)
        errors << "Image format #{mime_type} is not allowed. Allowed formats: #{allowed_formats.join(", ")}"
      end

      {
        valid: errors.empty?,
        mime_type: mime_type,
        size: data.bytesize,
        errors: errors
      }
    end

    # Encodes binary image data to base64 string.
    #
    # @param data [String] The binary image data.
    # @return [String] Base64 encoded string.
    #
    # @example
    #   encoded = VectorMCP::ImageUtil.encode_base64(File.binread("image.jpg"))
    def encode_base64(data)
      Base64.strict_encode64(data)
    end

    # Decodes base64 string to binary image data.
    #
    # @param base64_string [String] Base64 encoded image data.
    # @return [String] Binary image data.
    # @raise [ArgumentError] If base64 string is invalid.
    #
    # @example
    #   data = VectorMCP::ImageUtil.decode_base64(encoded_string)
    def decode_base64(base64_string)
      Base64.strict_decode64(base64_string)
    rescue ArgumentError => e
      raise ArgumentError, "Invalid base64 encoding: #{e.message}"
    end

    # Converts image data to MCP-compliant image content format.
    #
    # @param data [String] Binary image data or base64 encoded string.
    # @param mime_type [String, nil] MIME type (auto-detected if nil).
    # @param validate [Boolean] Whether to validate the image data.
    # @param max_size [Integer] Maximum allowed size for validation.
    # @return [Hash] MCP image content hash with :type, :data, and :mimeType.
    # @raise [ArgumentError] If validation fails.
    #
    # @example Convert binary image data
    #   content = VectorMCP::ImageUtil.to_mcp_image_content(
    #     File.binread("image.jpg")
    #   )
    #   # => { type: "image", data: "base64...", mimeType: "image/jpeg" }
    #
    # @example Convert base64 string with explicit MIME type
    #   content = VectorMCP::ImageUtil.to_mcp_image_content(
    #     base64_string,
    #     mime_type: "image/png",
    #     validate: false
    #   )
    def to_mcp_image_content(data, mime_type: nil, validate: true, max_size: DEFAULT_MAX_SIZE)
      # Determine if input is base64 or binary
      is_base64 = base64_string?(data)

      if is_base64
        # Decode to validate and detect format
        begin
          binary_data = decode_base64(data)
          base64_data = data
        rescue ArgumentError => e
          raise ArgumentError, "Invalid base64 image data: #{e.message}"
        end
      else
        # Assume binary data (dup to avoid modifying frozen strings)
        binary_data = data.dup.force_encoding(Encoding::ASCII_8BIT)
        base64_data = encode_base64(binary_data)
      end

      if validate
        validation = validate_image(binary_data, max_size: max_size)
        raise ArgumentError, "Image validation failed: #{validation[:errors].join(", ")}" unless validation[:valid]

        detected_mime_type = validation[:mime_type]
      else
        detected_mime_type = detect_image_format(binary_data)
      end

      final_mime_type = mime_type || detected_mime_type
      raise ArgumentError, "Could not determine image MIME type" if final_mime_type.nil?

      {
        type: "image",
        data: base64_data,
        mimeType: final_mime_type
      }
    end

    # Converts file path to MCP-compliant image content.
    #
    # @param file_path [String] Path to the image file.
    # @param validate [Boolean] Whether to validate the image.
    # @param max_size [Integer] Maximum allowed size for validation.
    # @return [Hash] MCP image content hash.
    # @raise [ArgumentError] If file doesn't exist or validation fails.
    #
    # @example
    #   content = VectorMCP::ImageUtil.file_to_mcp_image_content("./avatar.png")
    def file_to_mcp_image_content(file_path, validate: true, max_size: DEFAULT_MAX_SIZE)
      raise ArgumentError, "Image file not found: #{file_path}" unless File.exist?(file_path)

      raise ArgumentError, "Image file not readable: #{file_path}" unless File.readable?(file_path)

      binary_data = File.binread(file_path)
      to_mcp_image_content(binary_data, validate: validate, max_size: max_size)
    end

    # Extracts image metadata from binary data.
    #
    # @param data [String] Binary image data.
    # @return [Hash] Metadata hash with available information.
    #
    # @example
    #   metadata = VectorMCP::ImageUtil.extract_metadata(image_data)
    #   # => { mime_type: "image/jpeg", size: 102400, format: "JPEG" }
    def extract_metadata(data)
      return {} if data.nil? || data.empty?

      mime_type = detect_image_format(data)
      metadata = {
        size: data.bytesize,
        mime_type: mime_type
      }

      metadata[:format] = mime_type.split("/").last.upcase if mime_type

      # Add basic dimension detection for common formats
      metadata.merge!(extract_dimensions(data, mime_type))
    end

    # Checks if a string appears to be base64 encoded.
    #
    # @param string [String] The string to check.
    # @return [Boolean] True if the string appears to be base64.
    def base64_string?(string)
      return false if string.nil? || string.empty?

      # Base64 strings should only contain valid base64 characters
      # and be properly padded with correct length
      return false unless string.match?(%r{\A[A-Za-z0-9+/]*={0,2}\z})

      # Allow both padded and unpadded base64, but require proper structure
      # For unpadded base64, length should be at least 4 and not result in invalid decoding
      if string.include?("=")
        # Padded base64 must be multiple of 4
        (string.length % 4).zero?
      else
        # Unpadded base64 - try to decode to see if it's valid
        return false if string.length < 4

        begin
          # Add padding and try to decode
          padded = string + ("=" * (4 - (string.length % 4)) % 4)
          Base64.strict_decode64(padded)
          true
        rescue ArgumentError
          false
        end
      end
    end

    # Extracts basic image dimensions for common formats.
    # This is a simplified implementation; for production use,
    # consider using a proper image library like MiniMagick or ImageMagick.
    #
    # @param data [String] Binary image data.
    # @param mime_type [String] Detected MIME type.
    # @return [Hash] Hash containing width/height if detectable.
    def extract_dimensions(data, mime_type)
      case mime_type
      when "image/png"
        extract_png_dimensions(data)
      when "image/jpeg"
        extract_jpeg_dimensions(data)
      when "image/gif"
        extract_gif_dimensions(data)
      else
        {}
      end
    rescue StandardError
      {} # Return empty hash if dimension extraction fails
    end

    private

    # Extracts PNG dimensions from IHDR chunk.
    def extract_png_dimensions(data)
      return {} unless data.length > 24

      # PNG IHDR chunk starts at byte 16 and contains width/height
      width = data[16, 4].unpack1("N")
      height = data[20, 4].unpack1("N")

      { width: width, height: height }
    end

    # Extracts JPEG dimensions from SOF marker.
    def extract_jpeg_dimensions(data)
      # Simple JPEG dimension extraction
      # Look for SOF0 (Start of Frame) marker
      offset = 2
      while offset < data.length - 8
        marker = data[offset, 2].unpack1("n")
        length = data[offset + 2, 2].unpack1("n")

        # SOF0 marker (0xFFC0)
        if marker == 0xFFC0
          height = data[offset + 5, 2].unpack1("n")
          width = data[offset + 7, 2].unpack1("n")
          return { width: width, height: height }
        end

        offset += 2 + length
      end

      {}
    end

    # Extracts GIF dimensions from header.
    def extract_gif_dimensions(data)
      return {} unless data.length > 10

      # GIF dimensions are at bytes 6-9
      width = data[6, 2].unpack1("v")  # Little-endian
      height = data[8, 2].unpack1("v") # Little-endian

      { width: width, height: height }
    end

    module_function :extract_dimensions, :extract_png_dimensions, :extract_jpeg_dimensions, :extract_gif_dimensions
  end
end
