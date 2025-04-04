# frozen_string_literal: true

# Default handlers for core MCP methods
require_relative "../util"
require_relative "../errors"

module MCPRuby
  module Handlers
    module Core
      # Make methods available as class methods or instance methods

      module_function

      def ping(_params, _session, _server)
        MCPRuby.logger.debug("Handling ping request")
        {} # Empty object signifies success for ping
      end

      def initialized_notification(_params, session, server)
        server.logger.info("Client acknowledged initialization.")
        # Ensure session is marked as initialized, might be redundant but safe
        session.instance_variable_set(:@initialized, true) unless session.initialized?
      end

      def list_tools(_params, _session, server)
        server.logger.debug("Handling tools/list request")
        { tools: server.tools.values.map(&:as_mcp_definition) }
      end

      def call_tool(params, session, server)
        tool_name = params["name"]
        arguments = params["arguments"] || {}
        server.logger.debug { "Handling tools/call request for '#{tool_name}' with args: #{arguments.inspect}" }
        tool = server.tools[tool_name]
        raise MCPRuby::NotFoundError.new("Not Found", details: "Tool not found: #{tool_name}") unless tool

        # TODO: Add input schema validation here

        server.logger.debug { "Executing tool '#{tool_name}' with args: #{arguments.inspect}" }
        # Execute the tool's handler block, passing args and session
        result = tool.handler.call(arguments, session)

        # Convert result to MCP content format
        content = MCPRuby::Util.convert_to_mcp_content(result)
        { content: content, isError: false } # Assume success, handler errors caught higher up
      end

      def list_resources(_params, _session, server)
        server.logger.debug("Handling resources/list request")
        { resources: server.resources.values.map(&:as_mcp_definition) }
      end

      def read_resource(params, session, server)
        uri_s = params["uri"]
        server.logger.debug("Handling resources/read request for '#{uri_s}'")
        resource = server.resources[uri_s]
        raise MCPRuby::NotFoundError.new("Not Found", details: "Resource not found: #{uri_s}") unless resource

        # Execute the resource's handler block, passing session
        content_data = resource.handler.call(session)
        mime_type = resource.mime_type || "application/octet-stream" # Default if nil

        # Format based on expected return type
        content_result = case content_data
                         when String
                           { type: "text", text: content_data, mimeType: mime_type }
                         when ->(obj) { obj.respond_to?(:force_encoding) && obj.encoding == Encoding::ASCII_8BIT }
                           require "base64" # Ensure base64 is available
                           { type: "blob", blob: Base64.strict_encode64(content_data), mimeType: mime_type }
                         else
                           server.logger.warn("Unexpected resource content type: #{content_data.class}. Attempting JSON conversion.")
                           { type: "text", text: content_data.to_json, mimeType: "application/json" }
                         end
        # Merge uri into the content hash and wrap in contents array
        { contents: [content_result.merge(uri: uri_s)] }
      end

      def list_prompts(_params, _session, server)
        server.logger.debug("Handling prompts/list request")
        { prompts: server.prompts.values.map(&:as_mcp_definition) }
      end

      def get_prompt(params, session, server)
        prompt_name = params["name"]
        arguments = params["arguments"] || {}
        server.logger.debug("Handling prompts/get request for '#{prompt_name}'")
        prompt = server.prompts[prompt_name]
        raise MCPRuby::NotFoundError.new("Not Found", details: "Prompt not found: #{prompt_name}") unless prompt

        # TODO: Validate arguments against prompt.arguments definition

        server.logger.debug { "Rendering prompt '#{prompt_name}' with args: #{arguments.inspect}" }
        # Execute the prompt's handler block, passing args and session
        messages = prompt.handler.call(arguments, session) # Expects array of {role:, content:} hashes

        # TODO: Validate message structure?
        { messages: messages, description: prompt.description }.compact # Add description if present
      end

      def cancel_request_notification(params, _session, server)
        request_id_to_cancel = params["requestId"] || params["id"]
        if request_id_to_cancel
          server.logger.info("Received cancellation request for [#{request_id_to_cancel}]")
          request_info = server.in_flight_requests.delete(request_id_to_cancel)
          if request_info
            # TODO: Implement actual cancellation logic (e.g., kill thread/fiber)
            server.logger.info("Cancelled request [#{request_id_to_cancel}] (tracking removed)")
          else
            server.logger.warn("Request [#{request_id_to_cancel}] not found for cancellation")
          end
        else
          server.logger.warn("Cancellation notification missing request ID")
        end
      end
    end
  end
end
