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

        begin
          result = tool.handler.call(arguments)
          {
            isError: false,
            content: VectorMCP::Util.convert_to_mcp_content(result)
          }
        rescue StandardError => e
          {
            isError: true,
            content: [{ type: "text", text: "Error executing tool: #{e.message}" }]
          }
        end
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
        begin
          content_raw = resource.handler.call(params)
          contents = VectorMCP::Util.convert_to_mcp_content(content_raw, mime_type: resource.mime_type)
          contents.each do |item|
            # Add URI to each content item if not already present
            item[:uri] ||= uri_s
          end
          { contents: contents }
        rescue StandardError => e
          { isError: true, message: "Error reading resource: #{e.message}" }
        end
      end

      # List registered prompts
      def self.list_prompts(_params, _session, server)
        {
          prompts: server.prompts.values.map(&:as_mcp_definition)
        }
      end

      # Get a prompt by name
      def self.get_prompt(params, _session, server)
        prompt_name = params["name"]
        prompt = server.prompts[prompt_name]
        raise VectorMCP::NotFoundError.new("Not Found", details: "Prompt not found: #{prompt_name}") unless prompt

        arguments = params["arguments"] || {}
        begin
          prompt.handler.call(arguments, server)
          # Return the prompt result directly - it should conform to the prompt result format
        rescue StandardError => e
          { isError: true, message: "Error processing prompt: #{e.message}" }
        end
      end

      # --- Notification Handlers ---

      # Handle initialized notification (mark session as ready)
      def self.initialized_notification(_params, session, _server)
        # Additional initialization logic could go here
      end

      # Handle cancelation notification
      def self.cancel_request_notification(params, _session, server)
        request_id = params["id"]
        server.logger.info("Received cancellation request for ID: #{request_id}")
        # Application-specific cancellation logic would go here
        # Access in-flight requests via server.in_flight_requests[request_id]
      end
    end
  end
end
