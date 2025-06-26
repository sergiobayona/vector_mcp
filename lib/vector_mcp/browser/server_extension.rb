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
                maximum: 30_000
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

      # Configure browser-specific authorization policies
      # This provides common authorization patterns for browser automation
      def enable_browser_authorization!(&)
        raise ArgumentError, "Authorization must be enabled first" unless authorization.enabled

        # Create browser authorization context
        browser_auth = BrowserAuthorizationBuilder.new(authorization)

        # Execute the configuration block
        browser_auth.instance_eval(&) if block_given?

        @logger.info("Browser authorization policies configured")
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

      # Browser authorization configuration builder
      class BrowserAuthorizationBuilder
        def initialize(authorization_manager)
          @authorization = authorization_manager
        end

        # Allow navigation for specific users or roles
        def allow_navigation(condition = nil, &block)
          policy = condition || block || proc { true }
          add_browser_policy("browser_navigate", policy)
        end

        # Allow clicking for specific users or roles
        def allow_clicking(condition = nil, &block)
          policy = condition || block || proc { true }
          add_browser_policy("browser_click", policy)
        end

        # Allow typing for specific users or roles
        def allow_typing(condition = nil, &block)
          policy = condition || block || proc { true }
          add_browser_policy("browser_type", policy)
        end

        # Allow screenshots for specific users or roles
        def allow_screenshots(condition = nil, &block)
          policy = condition || block || proc { true }
          add_browser_policy("browser_screenshot", policy)
        end

        # Allow snapshots for specific users or roles
        def allow_snapshots(condition = nil, &block)
          policy = condition || block || proc { true }
          add_browser_policy("browser_snapshot", policy)
        end

        # Allow console access for specific users or roles
        def allow_console(condition = nil, &block)
          policy = condition || block || proc { true }
          add_browser_policy("browser_console", policy)
        end

        # Allow all browser tools for specific users or roles
        def allow_all_browser_tools(condition = nil, &block)
          policy = condition || block || proc { true }
          %w[browser_navigate browser_click browser_type browser_screenshot browser_snapshot browser_console].each do |tool_name|
            add_browser_policy(tool_name, policy)
          end
        end

        # Restrict browser access to specific domains
        def restrict_to_domains(*domains, &condition_block)
          domains.flatten
          @authorization.add_policy(:tool) do |user, action, tool|
            # Only apply to browser navigation
            next true unless tool.name == "browser_navigate"

            # Check user condition if provided
            next false if condition_block && !condition_block.call(user, action, tool)

            # Check if any allowed domain matches (this is a simplified check)
            # In practice, you'd want to check the actual URL being navigated to
            true # For now, just allow - domain checking would need URL parameter access
          end
        end

        # Common role-based policies
        def admin_full_access
          allow_all_browser_tools { |user, _action, _tool| user[:role] == "admin" }
        end

        def browser_user_full_access
          allow_all_browser_tools { |user, _action, _tool| %w[admin browser_user].include?(user[:role]) }
        end

        def read_only_access
          allow_navigation { |user, _action, _tool| %w[admin browser_user demo].include?(user[:role]) }
          allow_snapshots { |user, _action, _tool| %w[admin browser_user demo].include?(user[:role]) }
          allow_screenshots { |user, _action, _tool| %w[admin browser_user demo].include?(user[:role]) }
        end

        def demo_user_limited_access
          allow_navigation { |user, _action, _tool| user[:role] == "demo" }
          allow_snapshots { |user, _action, _tool| user[:role] == "demo" }
        end

        private

        def add_browser_policy(tool_name, policy_proc)
          @authorization.add_policy(:tool) do |user, action, tool|
            # Only apply to the specific browser tool
            next true unless tool.name == tool_name

            # Apply the browser-specific policy
            policy_proc.call(user, action, tool)
          end
        end
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
