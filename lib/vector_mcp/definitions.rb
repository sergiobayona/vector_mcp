# frozen_string_literal: true

require "uri"

module VectorMCP
  module Definitions
    # Represents a registered tool
    Tool = Struct.new(:name, :description, :input_schema, :handler) do
      def as_mcp_definition
        {
          name: name,
          description: description,
          inputSchema: input_schema # Expected to be a Hash representing JSON Schema
        }.compact # Remove nil values
      end
    end

    # Represents a registered resource
    Resource = Struct.new(:uri, :name, :description, :mime_type, :handler) do
      def as_mcp_definition
        {
          uri: uri.to_s,
          name: name,
          description: description,
          mimeType: mime_type
        }.compact
      end
    end

    # Represents a registered prompt
    Prompt = Struct.new(:name, :description, :arguments, :handler) do
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
