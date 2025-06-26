#!/usr/bin/env ruby
# frozen_string_literal: true

# Demo script showing browser automation via VectorMCP
# This script acts as an MCP client that communicates with a browser automation server
# to perform a Google search for the vector_mcp gem

require "net/http"
require "uri"
require "json"
require "securerandom"

class BrowserAutomationClient
  def initialize(server_host: "localhost", server_port: 8000)
    @server_host = server_host
    @server_port = server_port
    @session_id = nil
    @message_endpoint = nil
    @base_url = "http://#{server_host}:#{server_port}"
  end

  # Connect to the MCP server via SSE
  def connect
    puts "🔗 Connecting to VectorMCP server at #{@base_url}..."

    # Connect to SSE endpoint to get session info
    uri = URI("#{@base_url}/mcp/sse")
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = 5

    request = Net::HTTP::Get.new(uri)
    http.request(request) do |res|
      res.read_body do |chunk|
        # Parse SSE events to get the message endpoint
        if chunk.include?("event: endpoint")
          lines = chunk.split("\n")
          data_line = lines.find { |line| line.start_with?("data: ") }
          if data_line
            endpoint_data = JSON.parse(data_line.sub("data: ", ""))
            @message_endpoint = "#{@base_url}#{endpoint_data["uri"]}"
            # Extract session ID from the endpoint URL
            @session_id = URI.decode_www_form(URI.parse(@message_endpoint).query).to_h["session_id"]
            puts "✅ Connected! Session ID: #{@session_id}"
            puts "📡 Message endpoint: #{@message_endpoint}"
            return true
          end
        end
      end
    end

    false
  rescue StandardError => e
    puts "❌ Connection failed: #{e.message}"
    false
  end

  # Send a tool call to the MCP server
  def call_tool(tool_name, arguments = {})
    return nil unless @message_endpoint

    request_id = SecureRandom.uuid
    message = {
      jsonrpc: "2.0",
      id: request_id,
      method: "tools/call",
      params: {
        name: tool_name,
        arguments: arguments
      }
    }

    puts "🔧 Calling tool: #{tool_name}"
    puts "   Arguments: #{arguments}" unless arguments.empty?

    uri = URI(@message_endpoint)
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = 10
    http.read_timeout = 45 # Browser operations can take time

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = message.to_json

    response = http.request(request)

    if response.code == "202"
      puts "✅ Tool call accepted, waiting for result..."
      # In a real implementation, you'd listen to the SSE stream for the response
      # For this demo, we'll simulate getting the response
      sleep(2) # Simulate processing time
      simulate_tool_response(tool_name, arguments)
    else
      puts "❌ Tool call failed: #{response.code} #{response.message}"
      nil
    end
  rescue StandardError => e
    puts "❌ Tool call error: #{e.message}"
    nil
  end

  # Simulate tool responses for demo purposes
  # In a real implementation, these would come from the SSE stream
  def simulate_tool_response(tool_name, arguments)
    case tool_name
    when "browser_status"
      {
        extension_connected: false, # Chrome extension not actually connected in this demo
        stats: { pending_commands: 0, completed_commands: 0 }
      }
    when "browser_navigate"
      { url: arguments["url"], message: "Navigation simulated" }
    when "browser_type"
      { success: true, message: "Text input simulated" }
    when "browser_click"
      { success: true, message: "Click simulated" }
    when "browser_wait"
      { message: "Wait completed" }
    when "browser_snapshot"
      {
        snapshot: <<~YAML
          # Simulated ARIA snapshot
          - role: searchbox
            name: "Search"
            value: "#{arguments["search_term"] || "vector_mcp gem"}"
          - role: button
            name: "Google Search"
          - role: link
            name: "vector_mcp gem - Ruby package"
            href: "https://rubygems.org/gems/vector_mcp"
          - role: link
            name: "GitHub - sergiobayona/VectorMCP"
            href: "https://github.com/sergiobayona/VectorMCP"
        YAML
      }
    else
      { success: true, message: "Tool executed successfully" }
    end
  end

  def disconnect
    puts "👋 Disconnecting from server"
  end
end

def main
  puts "🤖 VectorMCP Browser Automation Demo"
  puts "=" * 50
  puts "This demo shows how to use VectorMCP's browser automation tools"
  puts "to perform a Google search for the vector_mcp gem."
  puts ""

  # Create client
  client = BrowserAutomationClient.new

  # Connect to server
  unless client.connect
    puts "❌ Failed to connect to VectorMCP server"
    puts "💡 Make sure the browser automation server is running:"
    puts "   ruby examples/browser_server.rb"
    exit 1
  end

  puts ""
  puts "🎯 Starting Google search automation..."
  puts ""

  # Step 1: Check browser status
  puts "1️⃣ Checking browser extension status..."
  status = client.call_tool("browser_status")
  if status
    if status[:extension_connected]
      puts "✅ Chrome extension is connected"
    else
      puts "⚠️  Chrome extension not connected (demo mode)"
      puts "💡 In real usage, install the Chrome extension first"
    end
  end

  # Step 2: Navigate to Google
  puts "\n2️⃣ Navigating to Google..."
  nav_result = client.call_tool("browser_navigate", {
                                  url: "https://www.google.com",
                                  include_snapshot: true
                                })
  puts "✅ Navigated to: #{nav_result[:url]}" if nav_result

  # Step 3: Wait for page to load
  puts "\n3️⃣ Waiting for page to load..."
  client.call_tool("browser_wait", { duration: 2000 })

  # Step 4: Type search query
  puts "\n4️⃣ Typing search query: 'vector_mcp gem'..."
  type_result = client.call_tool("browser_type", {
                                   text: "vector_mcp gem",
                                   selector: "input[name='q']", # Google search box
                                   include_snapshot: true
                                 })
  puts "✅ Search query entered" if type_result

  # Step 5: Submit search (press Enter or click search button)
  puts "\n5️⃣ Submitting search..."
  client.call_tool("browser_click", {
                     selector: "input[value='Google Search']"
                   })

  # Step 6: Wait for search results
  puts "\n6️⃣ Waiting for search results..."
  client.call_tool("browser_wait", { duration: 3000 })

  # Step 7: Get page snapshot to see results
  puts "\n7️⃣ Getting page snapshot..."
  snapshot_result = client.call_tool("browser_snapshot")
  if snapshot_result && snapshot_result[:snapshot]
    puts "📸 Page snapshot captured:"
    puts snapshot_result[:snapshot]
  end

  # Step 8: Click first organic search result
  puts "\n8️⃣ Clicking first organic search result..."
  click_result = client.call_tool("browser_click", {
                                    selector: "h3", # First search result heading
                                    include_snapshot: true
                                  })
  puts "✅ Clicked on first search result" if click_result

  # Step 9: Wait and take final snapshot
  puts "\n9️⃣ Waiting for page to load..."
  client.call_tool("browser_wait", { duration: 2000 })

  puts "\n🎉 Demo completed successfully!"
  puts ""
  puts "📋 Summary of actions performed:"
  puts "   ✅ Connected to VectorMCP server"
  puts "   ✅ Checked browser extension status"
  puts "   ✅ Navigated to Google"
  puts "   ✅ Entered search query: 'vector_mcp gem'"
  puts "   ✅ Submitted search"
  puts "   ✅ Clicked first search result"
  puts ""
  puts "💡 To run this with a real browser:"
  puts "   1. Start the browser server: ruby examples/browser_server.rb"
  puts "   2. Install the Chrome extension (to be created)"
  puts "   3. Run this demo script"

  client.disconnect
rescue Interrupt
  puts "\n👋 Demo interrupted"
rescue StandardError => e
  puts "❌ Demo failed: #{e.message}"
  puts e.backtrace.join("\n") if ENV["DEBUG"]
  exit 1
end

main if __FILE__ == $PROGRAM_NAME
