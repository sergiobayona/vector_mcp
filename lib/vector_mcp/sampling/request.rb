# frozen_string_literal: true

require_relative "../errors"

module VectorMCP
  module Sampling
    # Represents a sampling request to be sent to an MCP client.
    # It validates the basic structure of the request.
    class Request
      attr_reader :messages, :model_preferences, :system_prompt,
                  :include_context, :temperature, :max_tokens,
                  :stop_sequences, :metadata

      # Initializes a new Sampling::Request.
      #
      # @param params [Hash] The parameters for the sampling request.
      #   - :messages [Array<Hash>] (Required) Conversation history. Each message:
      #     - :role [String] (Required) "user" or "assistant".
      #     - :content [Hash] (Required) Message content.
      #       - :type [String] (Required) "text" or "image".
      #       - :text [String] (Optional) Text content if type is "text".
      #       - :data [String] (Optional) Base64 image data if type is "image".
      #       - :mime_type [String] (Optional) Mime type if type is "image".
      #   - :model_preferences [Hash] (Optional) Model selection preferences.
      #   - :system_prompt [String] (Optional) System prompt.
      #   - :include_context [String] (Optional) "none", "thisServer", "allServers".
      #   - :temperature [Float] (Optional) Sampling temperature.
      #   - :max_tokens [Integer] (Optional) Maximum tokens to generate.
      #   - :stop_sequences [Array<String>] (Optional) Stop sequences.
      #   - :metadata [Hash] (Optional) Provider-specific parameters.
      # @raise [ArgumentError] if the basic structure is invalid.
      def initialize(params = {})
        params = params.transform_keys(&:to_sym) # Normalize keys

        @messages = params[:messages]
        @model_preferences = params[:model_preferences]
        @system_prompt = params[:system_prompt]
        @include_context = params[:include_context]
        @temperature = params[:temperature]
        @max_tokens = params[:max_tokens]
        @stop_sequences = params[:stop_sequences]
        @metadata = params[:metadata]

        validate!
      end

      # Returns the request parameters as a hash, suitable for JSON serialization.
      #
      # @return [Hash]
      def to_h
        {
          messages: @messages,
          modelPreferences: @model_preferences, # MCP uses camelCase
          systemPrompt: @system_prompt,
          includeContext: @include_context,
          temperature: @temperature,
          maxTokens: @max_tokens,
          stopSequences: @stop_sequences,
          metadata: @metadata
        }.compact # Remove nil values
      end

      private

      def validate!
        raise ArgumentError, "'messages' array is required" unless @messages.is_a?(Array) && !@messages.empty?

        @messages.each_with_index do |msg, idx|
          validate_message(msg, idx)
        end

        validate_optional_params
      end

      def validate_message(msg, idx)
        raise ArgumentError, "Each message in 'messages' must be a Hash (at index #{idx})" unless msg.is_a?(Hash)

        msg_role = extract_message_role(msg)
        msg_content = extract_message_content(msg)

        validate_message_role(msg_role, idx)
        validate_message_content_structure(msg_content, idx)
        validate_content_by_type(msg_content, idx)
      end

      def extract_message_role(msg)
        msg[:role] || msg["role"]
      end

      def extract_message_content(msg)
        msg[:content] || msg["content"]
      end

      def validate_message_role(role, idx)
        raise ArgumentError, "Message role must be 'user' or 'assistant' (at index #{idx})" unless %w[user assistant].include?(role)
      end

      def validate_message_content_structure(content, idx)
        raise ArgumentError, "Message content must be a Hash (at index #{idx})" unless content.is_a?(Hash)
      end

      def validate_content_by_type(content, idx)
        content_type = content[:type] || content["type"]
        raise ArgumentError, "Message content type must be 'text' or 'image' (at index #{idx})" unless %w[text image].include?(content_type)

        case content_type
        when "text"
          validate_text_content(content, idx)
        when "image"
          validate_image_content(content, idx)
        end
      end

      def validate_text_content(content, idx)
        text_value = content[:text] || content["text"]
        return unless text_value.to_s.empty?

        raise ArgumentError, "Text content must not be empty if type is 'text' (at index #{idx})"
      end

      def validate_image_content(content, idx)
        validate_image_data(content, idx)
        validate_image_mime_type(content, idx)
      end

      def validate_image_data(content, idx)
        data_value = content[:data] || content["data"]
        return if data_value.is_a?(String) && !data_value.empty?

        raise ArgumentError, "Image content 'data' (base64 string) is required if type is 'image' (at index #{idx})"
      end

      def validate_image_mime_type(content, idx)
        mime_type_value = content[:mime_type] || content["mime_type"]
        return if mime_type_value.is_a?(String) && !mime_type_value.empty?

        raise ArgumentError, "Image content 'mime_type' is required if type is 'image' (at index #{idx})"
      end

      def validate_optional_params
        validate_model_preferences
        validate_system_prompt
        validate_include_context
        validate_temperature
        validate_max_tokens
        validate_stop_sequences
        validate_metadata
      end

      def validate_model_preferences
        return unless @model_preferences && !@model_preferences.is_a?(Hash)

        raise ArgumentError, "'model_preferences' must be a Hash if provided"
      end

      def validate_system_prompt
        return unless @system_prompt && !@system_prompt.is_a?(String)

        raise ArgumentError, "'system_prompt' must be a String if provided"
      end

      def validate_include_context
        return unless @include_context && !%w[none thisServer allServers].include?(@include_context)

        raise ArgumentError, "'include_context' must be 'none', 'thisServer', or 'allServers' if provided"
      end

      def validate_temperature
        return unless @temperature && !@temperature.is_a?(Numeric)

        raise ArgumentError, "'temperature' must be a Numeric if provided"
      end

      def validate_max_tokens
        return unless @max_tokens && !@max_tokens.is_a?(Integer)

        raise ArgumentError, "'max_tokens' must be an Integer if provided"
      end

      def validate_stop_sequences
        return unless @stop_sequences && !@stop_sequences.is_a?(Array)

        raise ArgumentError, "'stop_sequences' must be an Array if provided"
      end

      def validate_metadata
        return unless @metadata && !@metadata.is_a?(Hash)

        raise ArgumentError, "'metadata' must be a Hash if provided"
      end
    end
  end
end
