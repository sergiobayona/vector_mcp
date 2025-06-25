# frozen_string_literal: true

module VectorMCP
  module Browser
    # Server extension to add browser automation capabilities to VectorMCP servers
    module ServerExtension
      # Add browser automation tools to the server
      def register_browser_tools(server_host: "localhost", server_port: 8000)
        # Navigation tool
        register_tool(
          name: "browser_navigate",
          description: "Navigate to a URL in the browser",
          input_schema: {
            type: "object",
            properties: {
              url: { type: "string", description: "The URL to navigate to" },
              include_snapshot: { type: "boolean", description: "Whether to include ARIA snapshot in response", default: false }
            },
            required: ["url"]
          }
        ) do |arguments, session_context|
          navigate_tool = VectorMCP::Browser::Tools::Navigate.new(
            server_host: server_host, 
            server_port: server_port, 
            logger: @logger
          )
          navigate_tool.call(arguments, session_context)
        end

        # Click tool
        register_tool(
          name: "browser_click",
          description: "Click an element in the browser",
          input_schema: {
            type: "object",
            properties: {
              selector: { type: "string", description: "ARIA selector for the element to click" },
              coordinate: { 
                type: "array", 
                items: { type: "integer" }, 
                minItems: 2, 
                maxItems: 2,
                description: "X,Y coordinates to click if selector is not provided" 
              },
              include_snapshot: { type: "boolean", description: "Whether to include ARIA snapshot in response", default: true }
            }
          }
        ) do |arguments, session_context|
          click_tool = VectorMCP::Browser::Tools::Click.new(
            server_host: server_host, 
            server_port: server_port, 
            logger: @logger
          )
          click_tool.call(arguments, session_context)
        end

        # Type tool
        register_tool(
          name: "browser_type",
          description: "Type text in the browser",
          input_schema: {
            type: "object",
            properties: {
              text: { type: "string", description: "Text to type" },
              selector: { type: "string", description: "ARIA selector for the input element" },
              coordinate: { 
                type: "array", 
                items: { type: "integer" }, 
                minItems: 2, 
                maxItems: 2,
                description: "X,Y coordinates to click before typing if selector is not provided" 
              },
              include_snapshot: { type: "boolean", description: "Whether to include ARIA snapshot in response", default: true }
            },
            required: ["text"]
          }
        ) do |arguments, session_context|
          type_tool = VectorMCP::Browser::Tools::Type.new(
            server_host: server_host, 
            server_port: server_port, 
            logger: @logger
          )
          type_tool.call(arguments, session_context)
        end

        # Snapshot tool
        register_tool(
          name: "browser_snapshot",
          description: "Capture ARIA accessibility snapshot of the current page",
          input_schema: {
            type: "object",
            properties: {}
          }
        ) do |arguments, session_context|
          snapshot_tool = VectorMCP::Browser::Tools::Snapshot.new(
            server_host: server_host, 
            server_port: server_port, 
            logger: @logger
          )
          snapshot_tool.call(arguments, session_context)
        end

        # Screenshot tool
        register_tool(
          name: "browser_screenshot",
          description: "Take a screenshot of the current browser page",
          input_schema: {
            type: "object",
            properties: {}
          }
        ) do |arguments, session_context|
          screenshot_tool = VectorMCP::Browser::Tools::Screenshot.new(
            server_host: server_host, 
            server_port: server_port, 
            logger: @logger
          )
          screenshot_tool.call(arguments, session_context)
        end

        # Console tool
        register_tool(
          name: "browser_console",
          description: "Get browser console logs",
          input_schema: {
            type: "object",
            properties: {}
          }
        ) do |arguments, session_context|
          console_tool = VectorMCP::Browser::Tools::Console.new(
            server_host: server_host, 
            server_port: server_port, 
            logger: @logger
          )
          console_tool.call(arguments, session_context)
        end

        # Wait tool
        register_tool(
          name: "browser_wait",
          description: "Wait for a specified duration",
          input_schema: {
            type: "object",
            properties: {
              duration: { 
                type: "integer", 
                description: "Duration to wait in milliseconds", 
                default: 1000,
                minimum: 100,
                maximum: 30000
              }
            }
          }
        ) do |arguments, session_context|
          wait_tool = VectorMCP::Browser::Tools::Wait.new(
            server_host: server_host, 
            server_port: server_port, 
            logger: @logger
          )
          wait_tool.call(arguments, session_context)
        end

        @logger.info("Browser automation tools registered")
      end

      # Check if Chrome extension is connected (requires SSE transport)
      def browser_extension_connected?
        return false unless @transport.is_a?(VectorMCP::Transport::SSE)
        
        @transport.extension_connected?
      end

      # Get browser automation statistics (requires SSE transport)
      def browser_stats
        return { error: "Browser automation requires SSE transport" } unless @transport.is_a?(VectorMCP::Transport::SSE)
        
        @transport.browser_stats
      end
    end
  end
end

# Extend the Server class with browser capabilities
module VectorMCP
  class Server
    include Browser::ServerExtension
  end
end