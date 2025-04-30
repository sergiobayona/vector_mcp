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
          server.logger.error("Error executing tool '#{tool_name}': #{e.message}\n#{e.backtrace.first(5).join("\n")}")
          raise VectorMCP::InternalError.new("Tool execution failed", details: { tool: tool_name, error: e.message })
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
          server.logger.error("Error reading resource '#{uri_s}': #{e.message}\n#{e.backtrace.first(5).join("\n")}")
          raise VectorMCP::InternalError.new("Resource read failed", details: { uri: uri_s, error: e.message })
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
          # Call the registered handler, passing the arguments
          # The handler is expected to return a Hash like { messages: [...], description?: "..." }
          result_data = prompt.handler.call(arguments)

          # Basic validation of the handler's response
          unless result_data.is_a?(Hash) && result_data[:messages].is_a?(Array)
            # Log the invalid structure for debugging
            server.logger.error("Prompt handler for '#{prompt_name}' returned invalid data structure: #{result_data.inspect}")
            raise VectorMCP::InternalError.new("Prompt handler returned invalid data structure",
                                               details: { prompt: prompt_name, error: "Handler must return a Hash with a :messages Array" })
          end

          # Ensure all message contents are valid (basic check)
          # A more robust check might involve validating against Content schema
          result_data[:messages].each do |msg|
            next if msg.is_a?(Hash) && msg[:role] && msg[:content].is_a?(Hash) && msg[:content][:type]

            server.logger.error("Prompt handler for '#{prompt_name}' returned invalid message structure: #{msg.inspect}")
            raise VectorMCP::InternalError.new("Prompt handler returned invalid message structure",
                                               details: { prompt: prompt_name,
                                                          error: "Messages must be Hashes with :role and :content Hash (with :type)" })
          end

          # Return the result directly, assuming it matches the GetPromptResult structure
          # Example: { description: "Optional dynamic description", messages: [{role: "user", content: {type: "text", text: "..."}}] }
          result_data
        rescue VectorMCP::ProtocolError
          raise # Re-raise known protocol errors (like InternalError raised above)
        rescue StandardError => e
          server.logger.error("Error executing prompt handler for '#{prompt_name}': #{e.message}\n#{e.backtrace.first(5).join("\n")}")
          # Raise InternalError if the prompt's handler itself fails unexpectedly
          raise VectorMCP::InternalError.new("Prompt handler failed unexpectedly", details: { prompt: prompt_name, error: e.message })
        end
      end

      # --- Notification Handlers ---

      # Handle initialized notification (mark session as ready)
      def self.initialized_notification(_params, session, server)
        server.logger.info("Session initialized")
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
