# frozen_string_literal: true

module VectorMCP
  module Sampling
    # Represents the result of a sampling request returned by an MCP client.
    class Result
      attr_reader :raw_result, :model, :stop_reason, :role, :content

      # Initializes a new Sampling::Result.
      #
      # @param result_hash [Hash] The raw hash returned by the client for a sampling request.
      #   Expected keys (MCP spec uses camelCase, we symbolize and underscore internally):
      #   - 'model' [String] (Required) Name of the model used.
      #   - 'stopReason' [String] (Optional) Reason why generation stopped.
      #   - 'role' [String] (Required) "user" or "assistant".
      #   - 'content' [Hash] (Required) The generated content.
      #     - 'type' [String] (Required) "text" or "image".
      #     - 'text' [String] (Optional) Text content if type is "text".
      #     - 'data' [String] (Optional) Base64 image data if type is "image".
      #     - 'mimeType' [String] (Optional) Mime type if type is "image".
      def initialize(result_hash)
        @raw_result = result_hash.transform_keys { |k| k.to_s.gsub(/(.)([A-Z])/, '\1_\2').downcase.to_sym }

        @model = @raw_result[:model]
        @stop_reason = @raw_result[:stop_reason]
        @role = @raw_result[:role]
        @content = (@raw_result[:content] || {}).transform_keys(&:to_sym)

        validate!
      end

      # @return [Boolean] True if the content type is 'text'.
      def text?
        @content[:type] == "text"
      end

      # @return [Boolean] True if the content type is 'image'.
      def image?
        @content[:type] == "image"
      end

      # @return [String, nil] The text content if type is 'text', otherwise nil.
      def text_content
        text? ? @content[:text] : nil
      end

      # @return [String, nil] The base64 encoded image data if type is 'image', otherwise nil.
      def image_data
        image? ? @content[:data] : nil
      end

      # @return [String, nil] The mime type of the image if type is 'image', otherwise nil.
      def image_mime_type
        image? ? @content[:mime_type] : nil
      end

      private

      def validate!
        raise ArgumentError, "'model' is required in sampling result" if @model.to_s.empty?
        raise ArgumentError, "'role' is required in sampling result and must be 'user' or 'assistant'" unless %w[user assistant].include?(@role)
        raise ArgumentError, "'content' hash is required in sampling result" if @content.empty?

        content_type = @content[:type]
        raise ArgumentError, "Content 'type' must be 'text' or 'image' in sampling result" unless %w[text image].include?(content_type)

        if content_type == "text" && @content[:text].to_s.empty?
          # NOTE: Some models might return empty text, so we don't raise an error here but allow nil from text_content
          # raise ArgumentError, "Content 'text' must not be empty if type is 'text'"
        end

        return unless content_type == "image"
        raise ArgumentError, "Content 'data' (base64 string) is required if type is 'image'" if @content[:data].to_s.empty?
        return unless @content[:mime_type].to_s.empty?

        raise ArgumentError, "Content 'mime_type' is required if type is 'image'"
      end
    end
  end
end
