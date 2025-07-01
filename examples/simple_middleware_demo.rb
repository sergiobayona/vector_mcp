#!/usr/bin/env ruby
# frozen_string_literal: true

# Simple middleware demonstration
# Run with: ruby examples/simple_middleware_demo.rb

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "vector_mcp"

# Simple logging middleware
class SimpleLoggingMiddleware < VectorMCP::Middleware::Base
  def before_tool_call(context)
    puts "🚀 Starting tool: #{context.operation_name}"
  end

  def after_tool_call(context)
    puts "✅ Completed tool: #{context.operation_name}"
  end

  def on_tool_error(context)
    puts "❌ Error in tool: #{context.operation_name} - #{context.error.message}"
  end
end

def demo_middleware
  # Create server
  server = VectorMCP.new(name: "SimpleMiddlewareDemo", version: "1.0.0")

  # Register middleware
  server.use_middleware(SimpleLoggingMiddleware, %i[
                          before_tool_call after_tool_call on_tool_error
                        ])

  # Register a simple tool
  server.register_tool(
    name: "greet",
    description: "Greets someone",
    input_schema: {
      type: "object",
      properties: { name: { type: "string" } },
      required: ["name"]
    }
  ) do |args|
    "Hello, #{args["name"]}!"
  end

  puts "Simple Middleware Demo"
  puts "====================="
  puts "Middleware registered: #{server.middleware_stats[:total_hooks]} hooks"
  puts ""

  # Simulate a tool call (normally this would go through the transport layer)
  puts "Simulating tool calls:"
  puts ""

  # Create a mock session
  session = VectorMCP::Session.new(server)

  # Simulate successful tool call
  puts "1. Successful tool call:"
  begin
    params = { "name" => "greet", "arguments" => { "name" => "World" } }
    result = VectorMCP::Handlers::Core.call_tool(params, session, server)
    puts "   Result: #{result[:content].first[:text]}"
  rescue StandardError => e
    puts "   Error: #{e.message}"
  end

  puts ""
  puts "Middleware hooks executed automatically!"
  puts "This demonstrates how middleware can be transparently"
  puts "added to existing MCP operations."
end

# Run the demo if this file is executed directly
demo_middleware if __FILE__ == $PROGRAM_NAME
