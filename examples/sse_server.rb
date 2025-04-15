# frozen_string_literal: true

# Example SSE server implementation using VectorMCP

require "vector_mcp"

# Set debug logging level for development
VectorMCP.logger.level = Logger::DEBUG

# Create a server instance
server = VectorMCP::Server.new(
  name: "VectorMCP::SSEExampleServer",
  version: "0.0.1"
)

# Register a tool that echoes back the input
server.register_tool(
  name: "ruby_echo",
  description: "Echos back the message that was sent",
  parameters: {
    message: { type: :string, description: "Message to echo back" }
  }
) do |params|
  "You said via VectorMCP: #{params[:message]}"
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
  parameters: {
    name: { type: :string, description: "Name to greet" }
  }
) do |params|
  [
    { role: "system", content: { text: "You are a friendly assistant." } },
    { role: "user", content: { text: "Please greet #{params[:name]}" } },
    { role: "assistant", content: { text: "Hello #{params[:name]}! How can I help you today?" } }
  ]
end

# Start the SSE server
port = ENV["PORT"]&.to_i || 7464
begin
  puts "Starting VectorMCP SSE server on port #{port}..."
  server.start_sse(port: port)
rescue Interrupt
  puts "Server interrupted"
  exit 0
rescue StandardError => e
  puts "Error starting server: #{e.message}"
  puts e.backtrace.join("\n")
  exit 1
end
