#!/usr/bin/env ruby
# frozen_string_literal: true

# Secure Browser Server Example
# Demonstrates VectorMCP with browser automation and authentication

require_relative "../lib/vector_mcp"

# Create server with browser automation and authentication
server = VectorMCP::Server.new("secure-browser-server", version: "1.0.0")

# Enable API key authentication
api_keys = %w[browser-automation-key-123 demo-key-456]
server.enable_authentication!(strategy: :api_key, keys: api_keys)

# Enable authorization with browser-specific policies
server.enable_authorization! do
  # Only allow browser automation for authenticated users with 'browser' role
  authorize_tools do |user, _action, tool|
    if tool.name.start_with?("browser_")
      %w[browser_user admin].include?(user[:role])
    else
      true # Allow other tools
    end
  end
end

# Register browser automation tools
server.register_browser_tools

# Configure browser-specific authorization policies
server.enable_browser_authorization! do
  # Full access for admin users
  admin_full_access

  # Full browser access for browser_user role
  browser_user_full_access

  # Limited access for demo users (navigation and snapshots only)
  demo_user_limited_access
end

# Add a custom authentication strategy that sets user roles
server.auth_manager.add_custom_auth do |request|
  api_key = request[:headers]["X-API-Key"]

  case api_key
  when "browser-automation-key-123"
    {
      success: true,
      user: {
        id: "browser_user_1",
        name: "Browser Automation User",
        role: "browser_user",
        permissions: %w[browser_navigate browser_click browser_type browser_snapshot]
      }
    }
  when "demo-key-456"
    {
      success: true,
      user: {
        id: "demo_user_1",
        name: "Demo User",
        role: "demo",
        permissions: %w[browser_navigate browser_snapshot] # Limited permissions
      }
    }
  else
    { success: false, error: "Invalid API key" }
  end
end

# Set up security logging
security_logger = VectorMCP.logger_for("security.browser")

# Create transport with browser automation and security
transport = VectorMCP::Transport::SSE.new(server, port: 8000, host: "0.0.0.0")

puts <<~BANNER
  🔒 Secure Browser Automation Server Starting

  Server: #{server.name} v#{server.version}
  Transport: SSE on http://0.0.0.0:8000

  🔐 Authentication: API Key Strategy
  📋 Valid API Keys:
    - browser-automation-key-123 (browser_user role - full access)
    - demo-key-456 (demo role - limited access)

  🌐 Browser Endpoints:
    - http://localhost:8000/browser/ping (extension heartbeat)
    - http://localhost:8000/browser/poll (command polling)
    - http://localhost:8000/browser/result (result submission)
    - http://localhost:8000/browser/navigate (navigation commands)
    - http://localhost:8000/browser/click (click commands)
    - http://localhost:8000/browser/type (typing commands)
    - http://localhost:8000/browser/snapshot (page snapshots)
    - http://localhost:8000/browser/screenshot (screenshots)
    - http://localhost:8000/browser/console (console logs)
    - http://localhost:8000/browser/wait (wait commands)

  🔧 Chrome Extension Setup:
    1. Load extension from examples/chrome_extension/
    2. Configure authentication in extension storage:
       chrome.storage.local.set({
         vectormcp_auth: {
           enabled: true,
           strategy: 'api_key',
           apiKey: 'browser-automation-key-123'
         }
       })

  📊 Security Features:
    ✅ API Key Authentication
    ✅ Role-Based Authorization
    ✅ Browser-Specific Security Policies
    ✅ Structured Security Logging

  Press Ctrl+C to stop the server
BANNER

# Add signal handling for graceful shutdown
Signal.trap("INT") do
  puts "\n🛑 Shutting down secure browser server..."
  exit(0)
end

Signal.trap("TERM") do
  puts "\n🛑 Shutting down secure browser server..."
  exit(0)
end

# Log security configuration
security_logger.info("Secure browser server starting", context: {
                       authentication: server.security_status[:authentication],
                       authorization: server.security_status[:authorization],
                       browser_tools: server.tools.keys.select { |name| name.start_with?("browser_") }
                     })

# Start the server
begin
  server.run(transport: transport)
rescue StandardError => e
  security_logger.error("Server startup failed", context: { error: e.message, backtrace: e.backtrace[0..5] })
  puts "❌ Server failed to start: #{e.message}"
  exit(1)
end
