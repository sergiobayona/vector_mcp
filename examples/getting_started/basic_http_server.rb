#!/usr/bin/env ruby
# frozen_string_literal: true

# Example HTTP server implementation using VectorMCP

require_relative "../lib/vector_mcp"

# Configure logging using the new structured logging system
VectorMCP.configure_logging do
  level "DEBUG"
  console colorize: true, include_timestamp: true
end

# Create a server instance
server = VectorMCP.new(
  name: "VectorMCP::HTTPExampleServer",
  version: "0.0.1"
)

# Register a tool that echoes back the input
server.register_tool(
  name: "echo",
  description: "Echos back the message that was sent",
  input_schema: {
    type: "object",
    properties: {
      input: { type: "string", description: "Message to echo back" }
    },
    required: ["input"]
  }
) do |params|
  "You said via VectorMCP: #{params[:input]}"
end

# Register an in-memory resource
server.register_resource(
  uri: "memory://data/example.txt",
  name: "Example Text",
  description: "An example text resource with timestamp"
) do
  "This is an example text resource from VectorMCP. Current time: #{Time.now}"
end

# Register a simple greeting prompt
server.register_prompt(
  name: "simple_greeting",
  description: "Generates a simple greeting for the given name",
  arguments: [
    { name: "name", type: "string", description: "Name to greet" }
  ]
) do |params|
  [
    { role: "system", content: { text: "You are a friendly assistant." } },
    { role: "user", content: { text: "Please greet #{params[:name]}" } },
    { role: "assistant", content: { text: "Hello #{params[:name]}! How can I help you today?" } }
  ]
end

# Start the HTTP server
port = ENV["PORT"]&.to_i || 7464
begin
  puts "Starting VectorMCP HTTP server on port #{port}..."
  server.run(transport: :sse, options: { port: port, host: "localhost" })
rescue Interrupt
  puts "Server interrupted"
  exit 0
rescue StandardError => e
  puts "Error starting server: #{e.message}"
  puts e.backtrace.join("\n")
  exit 1
end
