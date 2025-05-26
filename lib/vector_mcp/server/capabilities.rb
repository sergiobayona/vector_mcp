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
        logger.debug("Prompts listChanged flag cleared.")
      end

      # Notifies connected clients that the list of available prompts has changed.
      # @return [void]
      def notify_prompts_list_changed
        return unless transport && @prompts_list_changed

        notification_method = "notifications/prompts/list_changed"
        begin
          if transport.respond_to?(:broadcast_notification)
            logger.info("Broadcasting prompts list changed notification.")
            transport.broadcast_notification(notification_method)
          elsif transport.respond_to?(:send_notification)
            logger.info("Sending prompts list changed notification (transport may broadcast or send to first client).")
            transport.send_notification(notification_method)
          else
            logger.warn("Transport does not support sending notifications/prompts/list_changed.")
          end
        rescue StandardError => e
          logger.error("Failed to send prompts list changed notification: #{e.class.name}: #{e.message}")
        end
      end

      # Resets the `roots_list_changed` flag to false.
      # @return [void]
      def clear_roots_list_changed
        @roots_list_changed = false
        logger.debug("Roots listChanged flag cleared.")
      end

      # Notifies connected clients that the list of available roots has changed.
      # @return [void]
      def notify_roots_list_changed
        return unless transport && @roots_list_changed

        notification_method = "notifications/roots/list_changed"
        begin
          if transport.respond_to?(:broadcast_notification)
            logger.info("Broadcasting roots list changed notification.")
            transport.broadcast_notification(notification_method)
          elsif transport.respond_to?(:send_notification)
            logger.info("Sending roots list changed notification (transport may broadcast or send to first client).")
            transport.send_notification(notification_method)
          else
            logger.warn("Transport does not support sending notifications/roots/list_changed.")
          end
        rescue StandardError => e
          logger.error("Failed to send roots list changed notification: #{e.class.name}: #{e.message}")
        end
      end

      # Registers a session as a subscriber to prompt list changes.
      # @api private
      def subscribe_prompts(session)
        @prompt_subscribers << session unless @prompt_subscribers.include?(session)
        logger.debug("Session subscribed to prompt list changes: #{session.object_id}")
      end

      private

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
