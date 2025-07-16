#!/usr/bin/env ruby
# frozen_string_literal: true

# Example HTTP Stream server implementation using VectorMCP
# This demonstrates the new MCP-compliant streamable HTTP transport

require_relative "../../lib/vector_mcp"

# Configure logging
ENV["VECTORMCP_LOG_LEVEL"] ||= "INFO"
ENV["VECTORMCP_LOG_FORMAT"] ||= "text"

# Create a server instance
server = VectorMCP.new(
  name: "VectorMCP::HttpStreamExampleServer",
  version: "0.0.1"
)

# Register a tool that echoes back the input
server.register_tool(
  name: "echo",
  description: "Echoes back the message that was sent",
  input_schema: {
    type: "object",
    properties: {
      input: { type: "string", description: "Message to echo back" }
    },
    required: ["input"]
  }
) do |params|
  "You said via VectorMCP HttpStream: #{params[:input]}"
end

# Register a tool that simulates a long-running process
server.register_tool(
  name: "long_process",
  description: "Simulates a long-running process with progress updates",
  input_schema: {
    type: "object",
    properties: {
      duration: { type: "integer", description: "Duration in seconds", minimum: 1, maximum: 30 }
    },
    required: ["duration"]
  }
) do |params, session_context|
  duration = params[:duration] || 5

  # Send progress notifications during the process
  (1..duration).each do |second|
    # Use the transport to send notifications
    if session_context.transport.respond_to?(:send_notification)
      session_context.transport.send_notification(
        session_context.id,
        "progress",
        {
          message: "Processing step #{second} of #{duration}",
          progress: (second.to_f / duration * 100).round(1)
        }
      )
    end
    sleep(1)
  end

  "Long process completed after #{duration} seconds"
end

# Register an in-memory resource
server.register_resource(
  uri: "memory://data/server_info.json",
  name: "Server Information",
  description: "Current server status and information"
) do
  {
    server_name: "HttpStream Example Server",
    version: "0.0.1",
    transport: "http_stream",
    timestamp: Time.now.iso8601,
    uptime_seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC).to_i
  }.to_json
end

# Register a prompt for generating HTTP client code
server.register_prompt(
  name: "http_client_code",
  description: "Generates example code for connecting to this HTTP stream server",
  arguments: [
    { name: "language", type: "string", description: "Programming language (javascript, python, curl)" }
  ]
) do |params|
  language = params[:language] || "javascript"

  code = case language.downcase
         when "javascript"
           <<~JS
             // Connect to VectorMCP HttpStream server
             const sessionId = 'your-session-id';

             // Send JSON-RPC request
             fetch('http://localhost:#{ENV["PORT"] || 7465}/mcp', {
               method: 'POST',
               headers: {
                 'Content-Type': 'application/json',
                 'Mcp-Session-Id': sessionId
               },
               body: JSON.stringify({
                 jsonrpc: '2.0',
                 id: 1,
                 method: 'tools/call',
                 params: {
                   name: 'echo',
                   arguments: { input: 'Hello from JavaScript!' }
                 }
               })
             });

             // Connect to SSE stream for notifications
             const eventSource = new EventSource(`http://localhost:#{ENV["PORT"] || 7465}/mcp`, {
               headers: { 'Mcp-Session-Id': sessionId }
             });
             eventSource.onmessage = (event) => {
               console.log('Received:', JSON.parse(event.data));
             };
           JS
         when "python"
           <<~PYTHON
             import requests
             import sseclient
             import json

             # Send JSON-RPC request
             session_id = 'your-session-id'
             response = requests.post('http://localhost:#{ENV["PORT"] || 7465}/mcp',#{" "}
               headers={
                 'Content-Type': 'application/json',
                 'Mcp-Session-Id': session_id
               },
               json={
                 'jsonrpc': '2.0',
                 'id': 1,
                 'method': 'tools/call',
                 'params': {
                   'name': 'echo',
                   'arguments': {'input': 'Hello from Python!'}
                 }
               }
             )

             # Connect to SSE stream
             stream = requests.get('http://localhost:#{ENV["PORT"] || 7465}/mcp',#{" "}
               headers={'Mcp-Session-Id': session_id},#{" "}
               stream=True
             )
             client = sseclient.SSEClient(stream)
             for event in client.events():
               print(f"Received: {event.data}")
           PYTHON
         when "curl"
           <<~CURL
             # Send JSON-RPC request
             curl -X POST http://localhost:#{ENV["PORT"] || 7465}/mcp \\
               -H "Content-Type: application/json" \\
               -H "Mcp-Session-Id: your-session-id" \\
               -d '{
                 "jsonrpc": "2.0",
                 "id": 1,
                 "method": "tools/call",
                 "params": {
                   "name": "echo",
                   "arguments": {"input": "Hello from curl!"}
                 }
               }'

             # Connect to SSE stream
             curl -H "Mcp-Session-Id: your-session-id" \\
               http://localhost:#{ENV["PORT"] || 7465}/mcp
           CURL
         else
           "Unsupported language: #{language}. Available: javascript, python, curl"
         end

  [
    { role: "system", content: { text: "You are a helpful coding assistant." } },
    { role: "user", content: { text: "Show me how to connect to the VectorMCP HttpStream server using #{language}" } },
    { role: "assistant", content: { text: "Here's example code to connect to the server:\n\n```#{language}\n#{code}\n```" } }
  ]
end

# Start the HTTP Stream server
port = ENV["PORT"]&.to_i || 7465
host = ENV["HOST"] || "localhost"

begin
  puts "Starting VectorMCP HttpStream server..."
  puts "  Server: http://#{host}:#{port}"
  puts "  Endpoint: http://#{host}:#{port}/mcp"
  puts "  Transport: HTTP Stream (MCP-compliant)"
  puts ""
  puts "Example requests:"
  puts "  POST /mcp - Send JSON-RPC requests"
  puts "  GET /mcp - Connect to SSE stream"
  puts "  DELETE /mcp - Terminate session"
  puts ""
  puts "Press Ctrl+C to stop the server"
  puts ""

  server.run(transport: :http_stream, host: host, port: port)
rescue Interrupt
  puts "\nServer interrupted"
  exit 0
rescue StandardError => e
  puts "Error starting server: #{e.message}"
  puts e.backtrace.join("\n")
  exit 1
end
