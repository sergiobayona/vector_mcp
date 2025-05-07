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
    #   The MIME type of the resource content (e.g., "text/plain", "application/json").
    # @!attribute handler [rw] Proc
    #   A callable that returns the content of the resource. It takes no arguments.
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
    #   A callable that generates the prompt content. It receives a hash of arguments.
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
    end
  end
end
