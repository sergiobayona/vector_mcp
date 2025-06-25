#!/usr/bin/env ruby
# frozen_string_literal: true

# Example browser automation server using VectorMCP
# This demonstrates browser automation capabilities through Chrome extension integration

require_relative "../lib/vector_mcp"

def main
  # Create server with browser automation capabilities
  server = VectorMCP::Server.new(
    name: "BrowserAutomationServer",
    version: "1.0.0"
  )

  # Register browser automation tools
  # These tools communicate with a Chrome extension via HTTP endpoints
  server.register_browser_tools(
    server_host: "localhost",
    server_port: 8000
  )

  # Add a simple tool to check browser connection status
  server.register_tool(
    name: "browser_status",
    description: "Check if Chrome extension is connected and get browser automation statistics",
    input_schema: {
      type: "object",
      properties: {}
    }
  ) do |_arguments, _session_context|
    {
      extension_connected: server.browser_extension_connected?,
      stats: server.browser_stats
    }
  end

  puts "🚀 Starting Browser Automation Server..."
  puts "📋 Available tools:"
  puts "   • browser_navigate - Navigate to URLs"
  puts "   • browser_click - Click elements"
  puts "   • browser_type - Type text"
  puts "   • browser_snapshot - Get page ARIA snapshot"
  puts "   • browser_screenshot - Take screenshots"
  puts "   • browser_console - Get console logs"
  puts "   • browser_wait - Wait/pause"
  puts "   • browser_status - Check extension status"
  puts ""
  puts "🌐 Server running on http://localhost:8000"
  puts "🔧 Chrome extension should connect to /browser/ endpoints"
  puts "📡 MCP clients can connect via:"
  puts "   • SSE: GET http://localhost:8000/mcp/sse"
  puts "   • JSON-RPC: POST to endpoint URL from SSE response"
  puts ""
  puts "Press Ctrl+C to stop"

  # Run with SSE transport (required for browser automation)
  server.run(transport: :sse, host: "localhost", port: 8000)
rescue Interrupt
  puts "\n👋 Browser automation server stopped"
rescue StandardError => e
  puts "❌ Error: #{e.message}"
  puts e.backtrace.join("\n") if ENV["DEBUG"]
  exit 1
end

main if __FILE__ == $PROGRAM_NAME