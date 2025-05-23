# frozen_string_literal: true

require "uri"

module VectorMCP
  # This module contains Struct definitions for Tools, Resources, and Prompts
  # that a VectorMCP::Server can provide.
  module Definitions
    # Represents a tool that can be executed by the AI model.
    #
    # @!attribute name [rw] String
    #   The unique name of the tool.
    # @!attribute description [rw] String
    #   A human-readable description of what the tool does.
    # @!attribute input_schema [rw] Hash
    #   A JSON Schema object describing the expected input for the tool.
    # @!attribute handler [rw] Proc
    #   A callable (e.g., a Proc or lambda) that executes the tool's logic.
    #   It receives the tool input (a Hash) as its argument.
    #   The input hash structure should match the input_schema.
    Tool = Struct.new(:name, :description, :input_schema, :handler) do
      # Converts the tool to its MCP definition hash.
      # @return [Hash] A hash representing the tool in MCP format.
      def as_mcp_definition
        {
          name: name,
          description: description,
          inputSchema: input_schema # Expected to be a Hash representing JSON Schema
        }.compact # Remove nil values
      end

      # Checks if this tool supports image inputs based on its input schema.
      # @return [Boolean] True if the tool's input schema includes image properties.
      def supports_image_input?
        return false unless input_schema.is_a?(Hash)

        properties = input_schema["properties"] || input_schema[:properties] || {}
        properties.any? do |_prop, schema|
          schema.is_a?(Hash) && (
            schema["format"] == "image" ||
            schema[:format] == "image" ||
            (schema["type"] == "string" && schema["contentEncoding"] == "base64" && schema["contentMediaType"]&.start_with?("image/")) ||
            (schema[:type] == "string" && schema[:contentEncoding] == "base64" && schema[:contentMediaType]&.start_with?("image/"))
          )
        end
      end
    end

    # Represents a resource (context or data) that can be provided to the AI model or user.
    #
    # @!attribute uri [rw] URI, String
    #   The unique URI identifying the resource.
    # @!attribute name [rw] String
    #   A human-readable name for the resource.
    # @!attribute description [rw] String
    #   A description of the resource content.
    # @!attribute mime_type [rw] String
    #   The MIME type of the resource content (e.g., "text/plain", "application/json", "image/jpeg").
    # @!attribute handler [rw] Proc
    #   A callable that returns the content of the resource. It may receive parameters from the request (e.g., for dynamic resources).
    Resource = Struct.new(:uri, :name, :description, :mime_type, :handler) do
      # Converts the resource to its MCP definition hash.
      # @return [Hash] A hash representing the resource in MCP format.
      def as_mcp_definition
        {
          uri: uri.to_s,
          name: name,
          description: description,
          mimeType: mime_type
        }.compact
      end

      # Checks if this resource represents an image.
      # @return [Boolean] True if the resource's MIME type indicates an image.
      def image_resource?
        !!mime_type&.start_with?("image/")
      end

      # Class method to create an image resource from a file path.
      # @param uri [String] The URI for the resource.
      # @param file_path [String] Path to the image file.
      # @param name [String] Human-readable name for the resource.
      # @param description [String] Description of the resource.
      # @return [Resource] A new Resource instance configured for the image file.
      def self.from_image_file(uri:, file_path:, name: nil, description: nil)
        raise ArgumentError, "Image file not found: #{file_path}" unless File.exist?(file_path)

        # Auto-detect MIME type
        require_relative "image_util"
        image_data = File.binread(file_path)
        detected_mime_type = VectorMCP::ImageUtil.detect_image_format(image_data)

        raise ArgumentError, "Could not detect image format for file: #{file_path}" unless detected_mime_type

        # Generate name and description if not provided
        default_name = name || File.basename(file_path)
        default_description = description || "Image file: #{file_path}"

        handler = lambda do |_params|
          VectorMCP::ImageUtil.file_to_mcp_image_content(file_path)
        end

        new(uri, default_name, default_description, detected_mime_type, handler)
      end

      # Class method to create an image resource from binary data.
      # @param uri [String] The URI for the resource.
      # @param image_data [String] Binary image data.
      # @param name [String] Human-readable name for the resource.
      # @param description [String] Description of the resource.
      # @param mime_type [String, nil] MIME type (auto-detected if nil).
      # @return [Resource] A new Resource instance configured for the image data.
      def self.from_image_data(uri:, image_data:, name:, description: nil, mime_type: nil)
        require_relative "image_util"

        # Detect or validate MIME type
        detected_mime_type = VectorMCP::ImageUtil.detect_image_format(image_data)
        final_mime_type = mime_type || detected_mime_type

        raise ArgumentError, "Could not determine MIME type for image data" unless final_mime_type

        default_description = description || "Image resource: #{name}"

        handler = lambda do |_params|
          VectorMCP::ImageUtil.to_mcp_image_content(image_data, mime_type: final_mime_type)
        end

        new(uri, name, default_description, final_mime_type, handler)
      end
    end

    # Represents a prompt or templated message workflow for users or AI models.
    #
    # @!attribute name [rw] String
    #   The unique name of the prompt.
    # @!attribute description [rw] String
    #   A human-readable description of the prompt.
    # @!attribute arguments [rw] Array<Hash>
    #   An array of argument definitions for the prompt, where each hash can contain
    #   `:name`, `:description`, and `:required` (Boolean).
    # @!attribute handler [rw] Proc
    #   A callable that generates the prompt content. It receives a hash of arguments, validated against the prompt's argument definitions.
    Prompt = Struct.new(:name, :description, :arguments, :handler) do
      # Converts the prompt to its MCP definition hash.
      # @return [Hash] A hash representing the prompt in MCP format.
      def as_mcp_definition
        {
          name: name,
          description: description,
          arguments: arguments # Expected to be an array of { name:, description:, required: } hashes
        }.compact
      end

      # Checks if this prompt supports image arguments.
      # @return [Boolean] True if any of the prompt arguments are configured for images.
      def supports_image_arguments?
        return false unless arguments.is_a?(Array)

        arguments.any? do |arg|
          arg.is_a?(Hash) && (
            arg["type"] == "image" ||
            arg[:type] == "image" ||
            (arg["description"] || arg[:description])&.downcase&.include?("image")
          )
        end
      end

      # Class method to create an image-enabled prompt with common image argument patterns.
      # @param name [String] The unique name of the prompt.
      # @param description [String] A human-readable description.
      # @param image_argument_name [String] Name of the image argument (default: "image").
      # @param additional_arguments [Array<Hash>] Additional prompt arguments.
      # @param handler [Proc] The prompt handler.
      # @return [Prompt] A new Prompt instance configured for image input.
      def self.with_image_support(name:, description:, image_argument_name: "image", additional_arguments: [], &handler)
        image_arg = {
          name: image_argument_name,
          description: "Image file path or image data to include in the prompt",
          required: false,
          type: "image"
        }

        all_arguments = [image_arg] + additional_arguments

        new(name, description, all_arguments, handler)
      end
    end

    # Represents an MCP root definition.
    # Roots define filesystem boundaries where servers can operate.
    Root = Struct.new(:uri, :name) do
      # Converts the root to its MCP definition hash.
      # @return [Hash] A hash representing the root in MCP format.
      def as_mcp_definition
        {
          uri: uri.to_s,
          name: name
        }.compact
      end

      # Validates that the root URI is properly formatted and secure.
      # @return [Boolean] True if the root is valid.
      # @raise [ArgumentError] If the root is invalid.
      def validate!
        # Validate URI format
        parsed_uri = begin
          URI(uri.to_s)
        rescue URI::InvalidURIError
          raise ArgumentError, "Invalid URI format: #{uri}"
        end

        # Currently, only file:// scheme is supported per MCP spec
        raise ArgumentError, "Only file:// URIs are supported for roots, got: #{parsed_uri.scheme}://" unless parsed_uri.scheme == "file"

        # Validate path exists and is a directory
        path = parsed_uri.path
        raise ArgumentError, "Root directory does not exist: #{path}" unless File.exist?(path)

        raise ArgumentError, "Root path is not a directory: #{path}" unless File.directory?(path)

        # Security check: ensure we can read the directory
        raise ArgumentError, "Root directory is not readable: #{path}" unless File.readable?(path)

        # Validate against path traversal attempts in the URI itself
        raise ArgumentError, "Root path contains unsafe traversal patterns: #{path}" if path.include?("..") || path.include?("./")

        true
      end

      # Class method to create a root from a local directory path.
      # @param path [String] Local filesystem path to the directory.
      # @param name [String] Human-readable name for the root.
      # @return [Root] A new Root instance.
      # @raise [ArgumentError] If the path is invalid or not accessible.
      def self.from_path(path, name: nil)
        # Expand path to get absolute path and resolve any relative components
        expanded_path = File.expand_path(path)

        # Create file:// URI
        uri = "file://#{expanded_path}"

        # Generate name if not provided
        default_name = name || File.basename(expanded_path)

        root = new(uri, default_name)
        root.validate! # Ensure the root is valid
        root
      end

      # Returns the filesystem path for file:// URIs.
      # @return [String] The filesystem path.
      # @raise [ArgumentError] If the URI is not a file:// scheme.
      def path
        parsed_uri = URI(uri.to_s)
        raise ArgumentError, "Cannot get path for non-file URI: #{uri}" unless parsed_uri.scheme == "file"

        parsed_uri.path
      end
    end
  end
end
