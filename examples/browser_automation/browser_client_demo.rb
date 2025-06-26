#!/usr/bin/env ruby
# frozen_string_literal: true

# Real MCP client demo that connects to a VectorMCP browser automation server
# This demonstrates the actual MCP protocol communication

require_relative "../lib/vector_mcp"
require "net/http"
require "json"
require "uri"

class MCPBrowserClient
  def initialize(server_url: "http://localhost:8000")
    @server_url = server_url
    @session_id = nil
    @message_url = nil
  end

  # Connect to the MCP server and establish session
  def connect
    puts "🔗 Connecting to MCP server at #{@server_url}..."

    # Step 1: Connect to SSE endpoint
    uri = URI("#{@server_url}/mcp/sse")
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = 10

    request = Net::HTTP::Get.new(uri)

    # Parse SSE stream to get session info
    http.request(request) do |res|
      if res.code != "200"
        puts "❌ Failed to connect: #{res.code} #{res.message}"
        return false
      end

      # Parse the SSE stream
      buffer = ""
      res.read_body do |chunk|
        buffer += chunk

        # Look for the endpoint event
        if buffer.include?("event: endpoint")
          lines = buffer.split("\n")
          data_line = lines.find { |line| line.start_with?("data: ") }

          if data_line
            # The data is the raw endpoint URL, not JSON
            endpoint_url = data_line.sub("data: ", "").strip
            @message_url = "#{@server_url}#{endpoint_url}"

            # Extract session ID from URL
            query_params = URI.decode_www_form(URI.parse(@message_url).query).to_h
            @session_id = query_params["session_id"]

            puts "✅ Connected! Session: #{@session_id}"
            puts "📡 Message URL: #{@message_url}"
            return true
          end
        end

        # Break after getting endpoint to avoid hanging
        break if @message_url
      end
    end

    false
  rescue StandardError => e
    puts "❌ Connection error: #{e.message}"
    false
  end

  # Send MCP initialize request
  def initialize_mcp
    send_request("initialize", {
                   protocolVersion: "2024-11-05",
                   capabilities: {
                     roots: { listChanged: false },
                     sampling: {}
                   },
                   clientInfo: {
                     name: "VectorMCP Browser Demo",
                     version: "1.0.0"
                   }
                 })
  end

  # List available tools
  def list_tools
    send_request("tools/list")
  end

  # Call a tool
  def call_tool(name, arguments = {})
    send_request("tools/call", {
                   name: name,
                   arguments: arguments
                 })
  end

  # Send a request to the MCP server
  def send_request(method, params = nil)
    return nil unless @message_url

    request_id = SecureRandom.uuid
    message = {
      jsonrpc: "2.0",
      id: request_id,
      method: method
    }
    message[:params] = params if params

    puts "📤 Sending: #{method}"
    puts "   Params: #{params.inspect}" if params && ENV["VERBOSE"]

    uri = URI(@message_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = 10
    http.read_timeout = 60

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = message.to_json

    response = http.request(request)

    case response.code
    when "202"
      puts "✅ Request accepted"
      # NOTE: In a real implementation, you'd need to listen to the SSE stream
      # for the actual response. For this demo, we'll return a success indicator.
      { success: true, message: "Request sent successfully" }
    when "200"
      JSON.parse(response.body)
    else
      puts "❌ Request failed: #{response.code} #{response.message}"
      { error: "Request failed", code: response.code }
    end
  rescue StandardError => e
    puts "❌ Request error: #{e.message}"
    { error: e.message }
  end

  def disconnect
    puts "👋 Disconnecting from MCP server"
  end
end

def demonstrate_google_search
  puts "🤖 VectorMCP Browser Automation - Google Search Demo"
  puts "=" * 60
  puts ""

  client = MCPBrowserClient.new

  # Connect to server
  unless client.connect
    puts "❌ Failed to connect to MCP server"
    puts ""
    puts "💡 To run this demo:"
    puts "   1. Start the browser server: ruby examples/browser_server.rb"
    puts "   2. Run this demo: ruby examples/browser_client_demo.rb"
    exit 1
  end

  # Initialize MCP protocol
  puts "\n📋 Initializing MCP protocol..."
  init_result = client.initialize_mcp
  puts "✅ MCP initialized" if init_result

  # List available tools
  puts "\n🔧 Listing available tools..."
  tools_result = client.list_tools
  puts "✅ Tools available (browser automation tools should be listed)" if tools_result && tools_result[:success]

  puts "\n🎯 Starting Google search automation sequence..."
  puts "   (Note: This demo shows the MCP protocol calls)"
  puts "   (Chrome extension needed for actual browser control)"
  puts ""

  # Demonstrate the search sequence
  steps = [
    {
      step: "1️⃣ Check browser status",
      tool: "browser_status",
      args: {}
    },
    {
      step: "2️⃣ Navigate to Google",
      tool: "browser_navigate",
      args: { url: "https://www.google.com", include_snapshot: false }
    },
    {
      step: "3️⃣ Wait for page load",
      tool: "browser_wait",
      args: { duration: 2000 }
    },
    {
      step: "4️⃣ Click search box and type query",
      tool: "browser_type",
      args: {
        text: "vector_mcp gem ruby",
        selector: "input[name='q']"
      }
    },
    {
      step: "5️⃣ Submit search",
      tool: "browser_click",
      args: { selector: "input[value='Google Search']" }
    },
    {
      step: "6️⃣ Wait for results",
      tool: "browser_wait",
      args: { duration: 3000 }
    },
    {
      step: "7️⃣ Take page snapshot",
      tool: "browser_snapshot",
      args: {}
    },
    {
      step: "8️⃣ Click first organic result",
      tool: "browser_click",
      args: { selector: "h3:first-of-type" }
    },
    {
      step: "9️⃣ Take screenshot of result page",
      tool: "browser_screenshot",
      args: {}
    }
  ]

  steps.each do |step_info|
    puts step_info[:step]
    result = client.call_tool(step_info[:tool], step_info[:args])

    if result && result[:success]
      puts "   ✅ Success"
    else
      puts "   ⚠️  Tool call sent (extension needed for execution)"
    end

    sleep(0.5) # Brief pause between steps
  end

  puts "\n🎉 Demo sequence completed!"
  puts ""
  puts "📋 Summary:"
  puts "   • Connected to VectorMCP server via MCP protocol"
  puts "   • Sent 9 browser automation commands"
  puts "   • Demonstrated Google search automation workflow"
  puts ""
  puts "🔧 For actual browser control:"
  puts "   1. Install Chrome extension (connects to /browser/ endpoints)"
  puts "   2. Extension polls server for commands"
  puts "   3. Extension executes commands in browser"
  puts "   4. Results sent back to MCP client"
  puts ""
  puts "🌟 Key advantages of this approach:"
  puts "   • Uses existing browser profiles (already logged in)"
  puts "   • Avoids bot detection (real browser fingerprint)"
  puts "   • Leverages VectorMCP's security and logging"
  puts "   • Compatible with any MCP client (Claude, VS Code, etc.)"

  client.disconnect
end

def main
  demonstrate_google_search
rescue Interrupt
  puts "\n👋 Demo interrupted"
rescue StandardError => e
  puts "❌ Demo failed: #{e.message}"
  puts e.backtrace.join("\n") if ENV["DEBUG"]
  exit 1
end

main if __FILE__ == $PROGRAM_NAME
