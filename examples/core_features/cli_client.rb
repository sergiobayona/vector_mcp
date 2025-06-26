# frozen_string_literal: true

# Simple example of a CLI-based MCP client that talks to an MCP server

require "vector_mcp"
require "json"

# Configure logging using the new structured logging system
VectorMCP.configure_logging do
  level "DEBUG"
  console colorize: true, include_timestamp: true
end

# Create a client instance and connect to the server
client = VectorMCP.new_client(endpoint: ARGV[0] || "http://localhost:7465/sse")

# Start the conversation with the server
session = client.start(
  session_id: ARGV[1],
  metadata: { client_type: "cli_example" }
)

puts "Connected to VectorMCP server (SessionID: #{session.session_id})"
puts "Server name: #{session.metadata[:server_name] || "unknown"}"
puts "Server version: #{session.metadata[:server_version] || "unknown"}"
puts

puts "Available tools:"
session.available_tools.each do |tool|
  puts "- #{tool[:name]}: #{tool[:description]}"
end
puts

puts "Available resources:"
session.available_resources.each do |resource|
  puts "- #{resource[:uri]}: #{resource[:name]} - #{resource[:description]}"
end
puts

puts "Available prompts:"
session.available_prompts.each do |prompt|
  puts "- #{prompt[:name]}: #{prompt[:description]}"
end
puts

# Call the echo tool
puts "Calling echo tool..."
result = session.call_tool("ruby_echo", { message: "Hello from VectorMCP CLI!" })
puts "Result: #{result}"
puts

# Fetch a resource
puts "Fetching resource..."
content = session.fetch_resource("memory://data/example.txt")
puts "Resource content: #{content}"
puts

# Use a prompt
puts "Using prompt..."
messages = session.use_prompt("simple_greeting", { name: "VectorMCP User" })
puts "Prompt messages:"
messages.each do |msg|
  puts "#{msg[:role]}: #{msg[:content][:text]}"
end
puts

puts "Disconnecting..."
client.stop
puts "Done!"
