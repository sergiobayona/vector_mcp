#!/usr/bin/env ruby
# frozen_string_literal: true

# Browser Authorization Demo
# Demonstrates fine-grained authorization policies for browser automation

require_relative "../lib/vector_mcp"

# Create server with browser automation
server = VectorMCP::Server.new("browser-auth-demo", version: "1.0.0")

# Enable authentication with multiple API keys
api_keys = [
  "admin-key-123",      # Admin user - full access
  "browser-key-456",    # Browser user - full browser access  
  "demo-key-789",       # Demo user - limited access
  "readonly-key-000"    # Read-only user - navigation and snapshots only
]
server.enable_authentication!(strategy: :api_key, keys: api_keys)

# Enable authorization
server.enable_authorization!

# Register browser automation tools
server.register_browser_tools

# Configure browser-specific authorization policies using the new DSL
server.enable_browser_authorization! do
  # Full access for admin users
  admin_full_access
  
  # Full browser access for browser users
  browser_user_full_access
  
  # Limited access for demo users
  demo_user_limited_access
  
  # Read-only access for readonly users
  read_only_access
  
  # Custom policy example: only allow screenshots for premium users
  allow_screenshots do |user, action, tool|
    %w[admin browser_user premium].include?(user[:role])
  end
end

# Add custom authentication to set user roles based on API key
server.auth_manager.add_custom_auth do |request|
  api_key = request[:headers]["X-API-Key"]
  
  case api_key
  when "admin-key-123"
    {
      success: true,
      user: {
        id: "admin_1",
        name: "Admin User",
        role: "admin",
        permissions: ["*"] # Full access
      }
    }
  when "browser-key-456"
    {
      success: true,
      user: {
        id: "browser_user_1", 
        name: "Browser Automation User",
        role: "browser_user",
        permissions: [
          "browser_navigate", "browser_click", "browser_type", 
          "browser_snapshot", "browser_screenshot", "browser_console"
        ]
      }
    }
  when "demo-key-789"
    {
      success: true,
      user: {
        id: "demo_user_1",
        name: "Demo User",
        role: "demo",
        permissions: ["browser_navigate", "browser_snapshot"]
      }
    }
  when "readonly-key-000"
    {
      success: true,
      user: {
        id: "readonly_user_1",
        name: "Read-Only User", 
        role: "readonly",
        permissions: ["browser_navigate", "browser_snapshot", "browser_screenshot"]
      }
    }
  else
    { success: false, error: "Invalid API key" }
  end
end

# Create transport
transport = VectorMCP::Transport::SSE.new(server, port: 8001, host: "0.0.0.0")

puts <<~BANNER
  🔐 Browser Authorization Demo Server
  
  Server: #{server.name} v#{server.version}
  Transport: SSE on http://0.0.0.0:8001
  
  🔑 API Keys and Permissions:
  
  👑 Admin User (admin-key-123):
     ✅ All browser tools (navigate, click, type, snapshot, screenshot, console)
     ✅ Full administrative access
  
  🔧 Browser User (browser-key-456):
     ✅ All browser tools (navigate, click, type, snapshot, screenshot, console)
     ❌ Non-browser administrative functions
  
  🎮 Demo User (demo-key-789):
     ✅ Navigation (browser_navigate)
     ✅ Snapshots (browser_snapshot) 
     ❌ Interaction (click, type)
     ❌ Screenshots
     ❌ Console access
  
  👁️  Read-Only User (readonly-key-000):
     ✅ Navigation (browser_navigate)
     ✅ Snapshots (browser_snapshot)
     ✅ Screenshots (browser_screenshot)
     ❌ Interaction (click, type)
     ❌ Console access
  
  🧪 Test Authorization:
     Use examples/test_browser_auth.rb with different API keys
     Update the script to test different keys and expected outcomes
  
  🌐 Browser Endpoints (all require authentication):
     - http://localhost:8001/browser/navigate
     - http://localhost:8001/browser/click
     - http://localhost:8001/browser/type
     - http://localhost:8001/browser/snapshot
     - http://localhost:8001/browser/screenshot
     - http://localhost:8001/browser/console
  
  🔧 Chrome Extension Authentication:
     Configure in extension: 
     chrome.storage.local.set({
       vectormcp_auth: {
         enabled: true,
         strategy: 'api_key',
         apiKey: 'browser-key-456'  // Use any valid key
       }
     })
  
  Press Ctrl+C to stop the server
BANNER

# Signal handling
Signal.trap("INT") do
  puts "\n🛑 Shutting down browser authorization demo..."
  exit(0)
end

Signal.trap("TERM") do
  puts "\n🛑 Shutting down browser authorization demo..."
  exit(0)
end

# Set up logging
auth_logger = VectorMCP.logger_for("security.browser")
auth_logger.info("Browser authorization demo starting", context: {
  authentication: server.security_status[:authentication],
  authorization: server.security_status[:authorization]
})

# Start the server
begin
  server.run(transport: transport)
rescue StandardError => e
  auth_logger.error("Server startup failed", context: { error: e.message })
  puts "❌ Server failed to start: #{e.message}"
  exit(1)
end