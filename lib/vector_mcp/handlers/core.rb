# frozen_string_literal: true

require "json"
require "uri"

module VectorMCP
  module Handlers
    # Provides default handlers for the core MCP methods.
    # These methods are typically registered on a {VectorMCP::Server} instance.
    # All public methods are designed to be called by the server's message dispatching logic.
    #
    # @see VectorMCP::Server#setup_default_handlers
    module Core
      # --- Request Handlers ---

      # Handles the `ping` request.
      #
      # @param _params [Hash] The request parameters (ignored).
      # @param _session [VectorMCP::Session] The current session (ignored).
      # @param _server [VectorMCP::Server] The server instance (ignored).
      # @return [Hash] An empty hash, as per MCP spec for ping.
      def self.ping(_params, _session, _server)
        VectorMCP.logger.debug("Handling ping request")
        {}
      end

      # Handles the `tools/list` request.
      #
      # @param _params [Hash] The request parameters (ignored).
      # @param _session [VectorMCP::Session] The current session (ignored).
      # @param server [VectorMCP::Server] The server instance.
      # @return [Hash] A hash containing an array of tool definitions.
      #   Example: `{ tools: [ { name: "my_tool", ... } ] }`
      def self.list_tools(_params, _session, server)
        {
          tools: server.tools.values.map(&:as_mcp_definition)
        }
      end

      # Handles the `tools/call` request.
      #
      # @param params [Hash] The request parameters.
      #   Expected keys: "name" (String), "arguments" (Hash, optional).
      # @param _session [VectorMCP::Session] The current session (ignored).
      # @param server [VectorMCP::Server] The server instance.
      # @return [Hash] A hash containing the tool call result or an error indication.
      #   Example success: `{ isError: false, content: [{ type: "text", ... }] }`
      # @raise [VectorMCP::NotFoundError] if the requested tool is not found.
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

      # Handles the `resources/list` request.
      #
      # @param _params [Hash] The request parameters (ignored).
      # @param _session [VectorMCP::Session] The current session (ignored).
      # @param server [VectorMCP::Server] The server instance.
      # @return [Hash] A hash containing an array of resource definitions.
      #   Example: `{ resources: [ { uri: "memory://data", name: "My Data", ... } ] }`
      def self.list_resources(_params, _session, server)
        {
          resources: server.resources.values.map(&:as_mcp_definition)
        }
      end

      # Handles the `resources/read` request.
      #
      # @param params [Hash] The request parameters.
      #   Expected key: "uri" (String).
      # @param _session [VectorMCP::Session] The current session (ignored).
      # @param server [VectorMCP::Server] The server instance.
      # @return [Hash] A hash containing an array of content items from the resource.
      #   Example: `{ contents: [{ type: "text", text: "...", uri: "memory://data" }] }`
      # @raise [VectorMCP::NotFoundError] if the requested resource URI is not found.
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

      # Handles the `prompts/list` request.
      # If the server supports dynamic prompt lists, this clears the `listChanged` flag.
      #
      # @param _params [Hash] The request parameters (ignored).
      # @param _session [VectorMCP::Session] The current session (ignored).
      # @param server [VectorMCP::Server] The server instance.
      # @return [Hash] A hash containing an array of prompt definitions.
      #   Example: `{ prompts: [ { name: "my_prompt", ... } ] }`
      def self.list_prompts(_params, _session, server)
        # Once the list is supplied, clear the listChanged flag
        result = {
          prompts: server.prompts.values.map(&:as_mcp_definition)
        }
        server.clear_prompts_list_changed if server.respond_to?(:clear_prompts_list_changed)
        result
      end

      # Handles the `roots/list` request.
      # Returns the list of available roots and clears the `listChanged` flag.
      #
      # @param _params [Hash] The request parameters (ignored).
      # @param _session [VectorMCP::Session] The current session (ignored).
      # @param server [VectorMCP::Server] The server instance.
      # @return [Hash] A hash containing an array of root definitions.
      #   Example: `{ roots: [ { uri: "file:///path/to/dir", name: "My Project" } ] }`
      def self.list_roots(_params, _session, server)
        # Once the list is supplied, clear the listChanged flag
        result = {
          roots: server.roots.values.map(&:as_mcp_definition)
        }
        server.clear_roots_list_changed if server.respond_to?(:clear_roots_list_changed)
        result
      end

      # Handles the `prompts/subscribe` request (placeholder).
      # This implementation is a simple acknowledgement.
      #
      # @param _params [Hash] The request parameters (ignored).
      # @param session [VectorMCP::Session] The current session.
      # @param server [VectorMCP::Server] The server instance.
      # @return [Hash] An empty hash.
      def self.subscribe_prompts(_params, session, server)
        # Use private helper via send to avoid making it public
        server.send(:subscribe_prompts, session) if server.respond_to?(:send)
        {}
      end

      # Handles the `prompts/get` request.
      # Validates arguments and the structure of the prompt handler's response.
      #
      # @param params [Hash] The request parameters.
      #   Expected keys: "name" (String), "arguments" (Hash, optional).
      # @param _session [VectorMCP::Session] The current session (ignored).
      # @param server [VectorMCP::Server] The server instance.
      # @return [Hash] The result from the prompt's handler, which should conform to MCP's GetPromptResult.
      # @raise [VectorMCP::NotFoundError] if the prompt name is not found.
      # @raise [VectorMCP::InvalidParamsError] if arguments are invalid.
      # @raise [VectorMCP::InternalError] if the prompt handler returns an invalid data structure.
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

      # Handles the `initialized` notification from the client.
      #
      # @param _params [Hash] The notification parameters (ignored).
      # @param _session [VectorMCP::Session] The current session (ignored, but state is on server).
      # @param server [VectorMCP::Server] The server instance.
      # @return [void]
      def self.initialized_notification(_params, _session, server)
        server.logger.info("Session initialized")
      end

      # Handles the `$/cancelRequest` notification from the client.
      #
      # @param params [Hash] The notification parameters. Expected key: "id".
      # @param _session [VectorMCP::Session] The current session (ignored).
      # @param server [VectorMCP::Server] The server instance.
      # @return [void]
      def self.cancel_request_notification(params, _session, server)
        request_id = params["id"]
        server.logger.info("Received cancellation request for ID: #{request_id}")
        # Application-specific cancellation logic would go here
        # Access in-flight requests via server.in_flight_requests[request_id]
      end

      # --- Helper methods (internal) ---

      # Fetches a prompt by its name from the server.
      # @api private
      # @param prompt_name [String] The name of the prompt to fetch.
      # @param server [VectorMCP::Server] The server instance.
      # @return [VectorMCP::Definitions::Prompt] The prompt definition.
      # @raise [VectorMCP::NotFoundError] if the prompt is not found.
      def self.fetch_prompt(prompt_name, server)
        prompt = server.prompts[prompt_name]
        return prompt if prompt

        raise VectorMCP::NotFoundError.new("Not Found", details: "Prompt not found: #{prompt_name}")
      end
      private_class_method :fetch_prompt

      # Validates arguments provided for a prompt against its definition.
      # @api private
      # @param prompt_name [String] The name of the prompt.
      # @param prompt [VectorMCP::Definitions::Prompt] The prompt definition.
      # @param arguments [Hash] The arguments supplied by the client.
      # @return [void]
      # @raise [VectorMCP::InvalidParamsError] if arguments are invalid (e.g., missing, unknown, wrong type).
      def self.validate_arguments!(prompt_name, prompt, arguments)
        ensure_hash!(prompt_name, arguments, "arguments")

        arg_defs = prompt.respond_to?(:arguments) ? (prompt.arguments || []) : []
        missing, unknown = argument_diffs(arg_defs, arguments)

        return if missing.empty? && unknown.empty?

        raise VectorMCP::InvalidParamsError.new("Invalid arguments",
                                                details: build_invalid_arg_details(prompt_name, missing, unknown))
      end
      private_class_method :validate_arguments!

      # Ensures a given value is a Hash.
      # @api private
      # @param prompt_name [String] The name of the prompt (for error reporting).
      # @param value [Object] The value to check.
      # @param field_name [String] The name of the field being checked (for error reporting).
      # @return [void]
      # @raise [VectorMCP::InvalidParamsError] if the value is not a Hash.
      def self.ensure_hash!(prompt_name, value, field_name)
        return if value.is_a?(Hash)

        raise VectorMCP::InvalidParamsError.new("#{field_name} must be an object", details: { prompt: prompt_name })
      end
      private_class_method :ensure_hash!

      # Calculates the difference between required/allowed arguments and supplied arguments.
      # @api private
      # @param arg_defs [Array<Hash>] The argument definitions for the prompt.
      # @param arguments [Hash] The arguments supplied by the client.
      # @return [Array(Array<String>, Array<String>)] A pair of arrays: [missing_keys, unknown_keys].
      def self.argument_diffs(arg_defs, arguments)
        required = arg_defs.select { |a| a[:required] }.map { |a| a[:name].to_s }
        allowed  = arg_defs.map { |a| a[:name].to_s }

        supplied_keys = arguments.keys.map(&:to_s)

        [required - supplied_keys, supplied_keys - allowed]
      end
      private_class_method :argument_diffs

      # Builds the details hash for an InvalidParamsError related to prompt arguments.
      # @api private
      # @param prompt_name [String] The name of the prompt.
      # @param missing [Array<String>] List of missing required argument names.
      # @param unknown [Array<String>] List of supplied argument names that are not allowed.
      # @return [Hash] The error details hash.
      def self.build_invalid_arg_details(prompt_name, missing, unknown)
        {}.tap do |details|
          details[:prompt]  = prompt_name
          details[:missing] = missing unless missing.empty?
          details[:unknown] = unknown unless unknown.empty?
        end
      end
      private_class_method :build_invalid_arg_details

      # Validates the structure of a prompt handler's response.
      # @api private
      # @param prompt_name [String] The name of the prompt (for error reporting).
      # @param result_data [Object] The data returned by the prompt handler.
      # @param server [VectorMCP::Server] The server instance (for logging).
      # @return [void]
      # @raise [VectorMCP::InternalError] if the response structure is invalid.
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
