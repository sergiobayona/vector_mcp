#!/usr/bin/env ruby
# frozen_string_literal: true

# If running from source checkout, setup load path
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "mcp_ruby"

# Configure the shared logger level if desired
MCPRuby.logger.level = Logger::DEBUG

# Create an instance of the server
server = MCPRuby.new_server(name: "MCPRuby::ExampleServer", version: "0.0.1")

# Register Tools, Resources, Prompts
server.register_tool(
  name: "ruby_echo",
  description: "Echoes the input string.",
  input_schema: {
    type: "object",
    properties: { message: { type: "string", description: "The message to echo." } },
    required: ["message"]
  }
) { |args, _session| "You said via MCPRuby: #{args["message"]}" }

server.register_resource(
  uri: "memory://data/example.txt",
  name: "Example Data",
  description: "Some simple data stored in server memory."
) { |_session| "This is the content of the example resource." }

server.register_prompt(
  name: "simple_greeting",
  description: "Generates a simple greeting.",
  arguments: [{ name: "name", required: true }]
) do |args, _session|
  [
    { role: "user", content: { type: "text", text: "Greet #{args["name"]} using MCPRuby style." } },
    { role: "assistant", content: { type: "text", text: "Alright, crafting a greeting for #{args["name"]} now." } }
  ]
end

# Run the server using stdio transport
begin
  server.run(transport: :stdio)
rescue MCPRuby::Error => e
  MCPRuby.logger.fatal("MCPRuby Error: #{e.message}")
  exit 1
rescue Interrupt
  MCPRuby.logger.info("Server interrupted.")
  exit 0
rescue StandardError => e
  MCPRuby.logger.fatal("Unexpected Error: #{e.message}\n#{e.backtrace.join("\n")}")
  exit 1
end
