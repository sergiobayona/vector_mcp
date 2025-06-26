#!/usr/bin/env ruby
# frozen_string_literal: true

# Simple Browser Server (No Security)
# Demonstrates VectorMCP browser automation without any security features

require_relative "../lib/vector_mcp"

# Create server WITHOUT any security features
server = VectorMCP::Server.new("simple-browser-server", version: "1.0.0")

# Register browser automation tools WITHOUT security
server.register_browser_tools

# Create transport WITHOUT security middleware
transport = VectorMCP::Transport::SSE.new(server, port: 8003, host: "0.0.0.0")

# Verify security is actually disabled
puts "🔍 Security Status Check:"
puts "  Authentication enabled: #{server.auth_manager.required?}"
puts "  Authorization enabled: #{server.authorization.required?}"
puts "  Security middleware enabled: #{server.security_enabled?}"
puts

puts <<~BANNER
  🌐 Simple Browser Server (No Security)
  
  Server: #{server.name} v#{server.version}
  Transport: SSE on http://0.0.0.0:8003
  
  🔓 Security: DISABLED
    - No authentication required
    - No authorization checks
    - No security logging
    - All browser endpoints are publicly accessible
  
  🌐 Browser Endpoints (no auth required):
    - http://localhost:8003/browser/ping
    - http://localhost:8003/browser/poll
    - http://localhost:8003/browser/result
    - http://localhost:8003/browser/navigate
    - http://localhost:8003/browser/click
    - http://localhost:8003/browser/type
    - http://localhost:8003/browser/snapshot
    - http://localhost:8003/browser/screenshot
    - http://localhost:8003/browser/console
    - http://localhost:8003/browser/wait
  
  🔧 Chrome Extension Setup (No Auth):
    1. Load extension from examples/chrome_extension/
    2. No authentication configuration needed
    3. Extension will connect automatically
  
  🧪 Test Without Authentication:
     curl -X POST http://localhost:8003/browser/navigate \\
          -H "Content-Type: application/json" \\
          -d '{"url": "https://example.com"}'
  
  ✅ Use Case: Development, testing, internal networks
  ⚠️  Warning: Do not use in production without security!
  
  Press Ctrl+C to stop the server
BANNER

# Signal handling
Signal.trap("INT") do
  puts "\n🛑 Shutting down simple browser server..."
  exit(0)
end

Signal.trap("TERM") do
  puts "\n🛑 Shutting down simple browser server..."
  exit(0)
end

# Start the server
begin
  server.run(transport: transport)
rescue StandardError => e
  puts "❌ Server failed to start: #{e.message}"
  exit(1)
end