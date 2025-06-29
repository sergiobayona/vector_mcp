#!/usr/bin/env ruby
# frozen_string_literal: true

# Simple example of a stdio-based MCP server
# It registers a couple of example tools, resources, and prompts.

require_relative "../../lib/vector_mcp"

# Logging can be configured via environment variables:
# VECTORMCP_LOG_LEVEL=DEBUG VECTORMCP_LOG_FORMAT=json ruby examples/getting_started/basic_stdio_server.rb

# Create a server instance with a name/version
server = VectorMCP.new(name: "VectorMCP::ExampleServer", version: "0.0.1")

# Register a simple echo tool
server.register_tool(
  name: "ruby_echo",
  description: "Echoes the input string.",
  input_schema: {
    type: "object",
    properties: {
      message: { type: "string" }
    },
    required: ["message"]
  }
) { |args, _session| "You said via VectorMCP: #{args["message"]}" }

# Register a simple in-memory resource
server.register_resource(
  uri: "memory://data/example.txt",
  name: "Example Data",
  description: "Some simple data stored in server memory."
) do |_session|
  "This is the content of the example resource. It's #{Time.now}."
end

# Register a simple greeting prompt
server.register_prompt(
  name: "simple_greeting",
  description: "Generates a simple greeting.",
  arguments: [
    { name: "name", description: "Name to greet", required: true }
  ]
) do |args|
  # Handler must return a Hash { description?: ..., messages: [...] }
  greeting_description = "Greeting prepared for #{args["name"]}."
  greeting_messages = [
    { role: "user", content: { type: "text", text: "Greet #{args["name"]} using VectorMCP style." } },
    { role: "assistant", content: { type: "text", text: "Alright, crafting a greeting for #{args["name"]} now." } }
  ]
  {
    description: greeting_description,
    messages: greeting_messages
  }
end

# Start the server!
begin
  server.run # By default, uses stdio transport
rescue VectorMCP::Error => e
  logger = VectorMCP.logger_for("server")
  logger.fatal("VectorMCP Error: #{e.message}")
  exit(1)
rescue Interrupt
  logger = VectorMCP.logger_for("server")
  logger.info("Server interrupted.")
  exit(0)
rescue StandardError => e
  logger = VectorMCP.logger_for("server")
  logger.fatal("Unexpected Error: #{e.message}\n#{e.backtrace.join("\n")}")
  exit(1)
end
