# frozen_string_literal: true

module VectorMCP
  class Server
    # Handles server capabilities and configuration
    module Capabilities
      # --- Server Information and Capabilities ---

      # Provides basic information about the server.
      # @return [Hash] Server name and version.
      def server_info
        { name: @name, version: @version }
      end

      # Returns the sampling configuration for this server.
      # @return [Hash] The sampling configuration including capabilities and limits.
      def sampling_config
        @sampling_config[:config]
      end

      # Describes the capabilities of this server according to MCP specifications.
      # @return [Hash] A capabilities object.
      def server_capabilities
        caps = {}
        caps[:tools] = { listChanged: false } unless @tools.empty?
        caps[:resources] = { subscribe: false, listChanged: false } unless @resources.empty?
        caps[:prompts] = { listChanged: @prompts_list_changed } unless @prompts.empty?
        caps[:roots] = { listChanged: true } unless @roots.empty?
        caps[:sampling] = @sampling_config[:capabilities]
        caps
      end

      # Resets the `prompts_list_changed` flag to false.
      # @return [void]
      def clear_prompts_list_changed
        @prompts_list_changed = false
      end

      # Notifies connected clients that the list of available prompts has changed.
      # @return [void]
      def notify_prompts_list_changed
        send_list_changed_notification("prompts") if @prompts_list_changed
      end

      # Resets the `roots_list_changed` flag to false.
      # @return [void]
      def clear_roots_list_changed
        @roots_list_changed = false
      end

      # Notifies connected clients that the list of available roots has changed.
      # @return [void]
      def notify_roots_list_changed
        send_list_changed_notification("roots") if @roots_list_changed
      end

      # Registers a session as a subscriber to prompt list changes.
      # @api private
      def subscribe_prompts(session)
        @prompt_subscribers << session unless @prompt_subscribers.include?(session)
        # Session subscribed to prompt list changes
      end

      private

      # Sends a `notifications/<kind>/list_changed` notification to the transport.
      # No-op if no transport is attached. Logs a warning if the transport does not
      # implement `send_notification` (intentional extension point for alternate
      # transports).
      # @api private
      # @param kind [String] One of "prompts" or "roots".
      def send_list_changed_notification(kind)
        return unless transport

        notification_method = "notifications/#{kind}/list_changed"
        if transport.respond_to?(:send_notification)
          logger.debug("Sending #{kind} list changed notification.")
          transport.send_notification(notification_method)
        else
          logger.warn("Transport does not support sending #{notification_method}.")
        end
      rescue StandardError => e
        logger.error("Failed to send #{kind} list changed notification: #{e.class.name}: #{e.message}")
      end

      # Configures sampling capabilities based on provided configuration.
      # @api private
      def configure_sampling_capabilities(config)
        defaults = {
          enabled: true,
          methods: ["createMessage"],
          supports_streaming: false,
          supports_tool_calls: false,
          supports_images: false,
          max_tokens_limit: nil,
          timeout_seconds: 30,
          context_inclusion_methods: %w[none thisServer],
          model_preferences_supported: true
        }

        resolved_config = defaults.merge(config.transform_keys(&:to_sym))
        capabilities = build_sampling_capabilities_object(resolved_config)

        {
          config: resolved_config,
          capabilities: capabilities
        }
      end

      # Builds the complete sampling capabilities object.
      # @api private
      def build_sampling_capabilities_object(config)
        return {} unless config[:enabled]

        {
          methods: config[:methods],
          features: build_sampling_features(config),
          limits: build_sampling_limits(config),
          contextInclusion: config[:context_inclusion_methods]
        }
      end

      # Builds the features section of sampling capabilities.
      # @api private
      def build_sampling_features(config)
        features = {}
        features[:streaming] = true if config[:supports_streaming]
        features[:toolCalls] = true if config[:supports_tool_calls]
        features[:images] = true if config[:supports_images]
        features[:modelPreferences] = true if config[:model_preferences_supported]
        features
      end

      # Builds the limits section of sampling capabilities.
      # @api private
      def build_sampling_limits(config)
        limits = {}
        limits[:maxTokens] = config[:max_tokens_limit] if config[:max_tokens_limit]
        limits[:defaultTimeout] = config[:timeout_seconds] if config[:timeout_seconds]
        limits
      end
    end
  end
end
