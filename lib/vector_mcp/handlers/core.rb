# frozen_string_literal: true

require "json"
require "uri"

module VectorMCP
  module Handlers
    # Default handlers for core MCP methods
    module Core
      # --- Request Handlers ---

      # Handle ping request (return empty result)
      def self.ping(_params, _session, _server)
        VectorMCP.logger.debug("Handling ping request")
        {}
      end

      # List registered tools
      def self.list_tools(_params, _session, server)
        {
          tools: server.tools.values.map(&:as_mcp_definition)
        }
      end

      # Call a registered tool
      def self.call_tool(params, _session, server)
        tool_name = params["name"]
        arguments = params["arguments"] || {}

        tool = server.tools[tool_name]
        raise VectorMCP::NotFoundError.new("Not Found", details: "Tool not found: #{tool_name}") unless tool

        # Let StandardError propagate to Server#handle_request
        result = tool.handler.call(arguments)
        {
          isError: false,
          content: VectorMCP::Util.convert_to_mcp_content(result)
        }
      end

      # List registered resources
      def self.list_resources(_params, _session, server)
        {
          resources: server.resources.values.map(&:as_mcp_definition)
        }
      end

      # Read a resource's contents
      def self.read_resource(params, _session, server)
        uri_s = params["uri"]
        raise VectorMCP::NotFoundError.new("Not Found", details: "Resource not found: #{uri_s}") unless server.resources[uri_s]

        resource = server.resources[uri_s]
        # Let StandardError propagate to Server#handle_request
        content_raw = resource.handler.call(params)
        contents = VectorMCP::Util.convert_to_mcp_content(content_raw, mime_type: resource.mime_type)
        contents.each do |item|
          # Add URI to each content item if not already present
          item[:uri] ||= uri_s
        end
        { contents: contents }
      end

      # List registered prompts
      def self.list_prompts(_params, _session, server)
        # Once the list is supplied, clear the listChanged flag
        result = {
          prompts: server.prompts.values.map(&:as_mcp_definition)
        }
        server.clear_prompts_list_changed if server.respond_to?(:clear_prompts_list_changed)
        result
      end

      # Subscribe for prompt list change notifications (simple ack)
      def self.subscribe_prompts(_params, session, server)
        # Use private helper via send to avoid making it public
        server.send(:subscribe_prompts, session) if server.respond_to?(:send)
        {}
      end

      # Get a prompt by name
      def self.get_prompt(params, _session, server)
        prompt_name = params["name"]
        prompt      = fetch_prompt(prompt_name, server)

        arguments = params["arguments"] || {}
        validate_arguments!(prompt_name, prompt, arguments)

        # Call the registered handler after arguments were validated
        result_data = prompt.handler.call(arguments)

        validate_prompt_response!(prompt_name, result_data, server)

        # Return the handler response directly (must match GetPromptResult schema)
        result_data
      end

      # --- Notification Handlers ---

      # Handle initialized notification (mark session as ready)
      def self.initialized_notification(_params, _session, server)
        server.logger.info("Session initialized")
      end

      # Handle cancelation notification
      def self.cancel_request_notification(params, _session, server)
        request_id = params["id"]
        server.logger.info("Received cancellation request for ID: #{request_id}")
        # Application-specific cancellation logic would go here
        # Access in-flight requests via server.in_flight_requests[request_id]
      end

      # --- Helper methods (internal) ---

      def self.fetch_prompt(prompt_name, server)
        prompt = server.prompts[prompt_name]
        return prompt if prompt

        raise VectorMCP::NotFoundError.new("Not Found", details: "Prompt not found: #{prompt_name}")
      end
      private_class_method :fetch_prompt

      def self.validate_arguments!(prompt_name, prompt, arguments)
        ensure_hash!(prompt_name, arguments)

        arg_defs = prompt.respond_to?(:arguments) ? (prompt.arguments || []) : []
        missing, unknown = argument_diffs(arg_defs, arguments)

        return if missing.empty? && unknown.empty?

        raise VectorMCP::InvalidParamsError.new("Invalid arguments",
                                                details: build_invalid_arg_details(prompt_name, missing, unknown))
      end
      private_class_method :validate_arguments!

      # Ensure arguments is a Hash
      def self.ensure_hash!(prompt_name, arguments)
        return if arguments.is_a?(Hash)

        raise VectorMCP::InvalidParamsError.new("arguments must be an object", details: { prompt: prompt_name })
      end
      private_class_method :ensure_hash!

      # Compute lists of missing and unknown keys
      def self.argument_diffs(arg_defs, arguments)
        required = arg_defs.select { |a| a[:required] }.map { |a| a[:name].to_s }
        allowed  = arg_defs.map { |a| a[:name].to_s }

        supplied_keys = arguments.keys.map(&:to_s)

        [required - supplied_keys, supplied_keys - allowed]
      end
      private_class_method :argument_diffs

      # Build error details hash for invalid arguments
      def self.build_invalid_arg_details(prompt_name, missing, unknown)
        {}.tap do |details|
          details[:prompt]  = prompt_name
          details[:missing] = missing unless missing.empty?
          details[:unknown] = unknown unless unknown.empty?
        end
      end
      private_class_method :build_invalid_arg_details

      def self.validate_prompt_response!(prompt_name, result_data, server)
        unless result_data.is_a?(Hash) && result_data[:messages].is_a?(Array)
          server.logger.error("Prompt handler for '#{prompt_name}' returned invalid data structure: #{result_data.inspect}")
          raise VectorMCP::InternalError.new("Prompt handler returned invalid data structure",
                                             details: { prompt: prompt_name, error: "Handler must return a Hash with a :messages Array" })
        end

        result_data[:messages].each do |msg|
          next if msg.is_a?(Hash) && msg[:role] && msg[:content].is_a?(Hash) && msg[:content][:type]

          server.logger.error("Prompt handler for '#{prompt_name}' returned invalid message structure: #{msg.inspect}")
          raise VectorMCP::InternalError.new("Prompt handler returned invalid message structure",
                                             details: { prompt: prompt_name,
                                                        error: "Messages must be Hashes with :role and :content Hash (with :type)" })
        end
      end
      private_class_method :validate_prompt_response!
    end
  end
end
