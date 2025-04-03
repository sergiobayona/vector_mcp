#!/usr/bin/env ruby
# frozen_string_literal: true

# If running from source checkout, setup load path
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "mcp_ruby"

# Configure the shared logger level if desired
MCPRuby.logger.level = Logger::DEBUG

# Create an instance of the server
server = MCPRuby.new_server(name: "MCPRuby::ExampleServer", version: "0.0.1")

# --- Example Tool ---
server.register_tool(
  name: "ruby_echo",
  description: "Echoes the input string.",
  input_schema: {
    type: "object",
    properties: {
      message: { type: "string", description: "The message to echo." }
    },
    required: ["message"]
  }
) do |args, _session|
  input_message = args["message"] || args[:message]
  server.logger.info("Echoing: #{input_message}")
  "You said via MCPRuby: #{input_message}"
end

# --- Example Resource ---
server.register_resource(
  uri: "memory://data/example.txt",
  name: "Example Data",
  description: "Some simple data stored in server memory.",
  mime_type: "text/plain"
) do |_session|
  server.logger.info("Reading memory resource")
  "This is the content of the example resource.\nTimestamp: #{Time.now}"
end

# --- Example Prompt ---
server.register_prompt(
  name: "simple_greeting",
  description: "Generates a simple greeting.",
  arguments: [
    { name: "name", description: "The name of the person to greet.", required: true }
  ]
) do |args, _session|
  user_name = args["name"] || args[:name]
  server.logger.info("Generating greeting for: #{user_name}")
  [
    { role: "user", content: { type: "text", text: "Greet #{user_name} using MCPRuby style." } },
    { role: "assistant", content: { type: "text", text: "Alright, crafting a greeting for #{user_name} now." } }
  ]
end

# --- Run the server using the default stdio transport ---
begin
  server.run(transport: :stdio)
rescue MCPRuby::Error => e
  MCPRuby.logger.fatal("MCPRuby Error: #{e.message}")
  exit 1
rescue StandardError => e
  MCPRuby.logger.fatal("Unexpected Error: #{e.message}\n#{e.backtrace.join("\n")}")
  exit 1
end
