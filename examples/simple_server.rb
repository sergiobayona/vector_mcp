#!/usr/bin/env ruby
# frozen_string_literal: true

# If running from source checkout, setup load path
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "mcp_ruby"

# Configure the shared logger level if desired
MCPRuby.logger.level = Logger::DEBUG

# Create an instance of the server
server = MCPRuby.new_server(name: "MCPRuby::ExampleSSE_Server", version: "0.0.1")

# --- Register Tools, Resources, Prompts (same as before) ---
# ... (copy the register_tool, register_resource, register_prompt blocks) ...
server.register_tool(
  name: "ruby_echo",
  description: "Echoes the input string.",
  input_schema: {
    type: "object",
    properties: { message: { type: "string", description: "The message to echo." } },
    required: ["message"]
  }
) { |args, _session| "You said via MCPRuby SSE: #{args["message"]}" }

server.register_resource(
  uri: "memory://data/example.txt", name: "Example Data", description: "Test data."
) { |_session| "SSE Resource Content at #{Time.now}" }

server.register_prompt(
  name: "simple_greeting", description: "Greets someone.", arguments: [{ name: "name", required: true }]
) { |args, _session| [{ role: "user", content: { type: "text", text: "Hi #{args["name"]} from SSE!" } }] }

# --- Run the server using SSE transport ---
begin
  server.run(transport: :sse, options: { host: "localhost", port: 8080, path_prefix: "/mcp" })
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
