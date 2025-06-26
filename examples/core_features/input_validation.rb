#!/usr/bin/env ruby
# frozen_string_literal: true

# This example demonstrates both types of validation in VectorMCP:
# 1. Schema Validation (during tool registration)
# 2. Input Validation (during tool execution)

require_relative "../lib/vector_mcp"

puts "=== VectorMCP Validation Demo ==="
puts

# Create a server
server = VectorMCP.new(name: "ValidationDemo", version: "1.0.0")

puts "1. SCHEMA VALIDATION (during registration)"
puts "   Validates that schemas themselves are well-formed JSON schemas"
puts

# Example 1: Valid schema registration
puts "✓ Registering tool with valid schema..."
server.register_tool(
  name: "valid_tool",
  description: "A tool with a valid schema",
  input_schema: {
    type: "object",
    properties: {
      name: { type: "string", minLength: 1 },
      age: { type: "integer", minimum: 0, maximum: 150 }
    },
    required: ["name"],
    additionalProperties: false
  }
) { |args| "Hello #{args["name"]}!" }
puts "   Tool registered successfully"
puts

# Example 2: Invalid schema registration (this will fail)
puts "✗ Attempting to register tool with invalid schema..."
begin
  server.register_tool(
    name: "invalid_tool",
    description: "A tool with invalid schema",
    input_schema: {
      type: "object",
      properties: {
        email: { type: "string", minimum: "not_a_number" } # Invalid: minimum should be number
      }
    }
  ) { |_args| "This won't work" }
rescue ArgumentError => e
  puts "   ❌ Registration failed: #{e.message}"
end
puts

puts "2. INPUT VALIDATION (during tool execution)"
puts "   Validates user arguments against the registered schema"
puts

# Create a session for testing
session = VectorMCP::Session.new(server)
session.initialize!({
                      "protocolVersion" => "2024-11-05",
                      "clientInfo" => { "name" => "demo-client", "version" => "1.0.0" },
                      "capabilities" => {}
                    })

# Example 3: Valid input
puts "✓ Calling tool with valid arguments..."
begin
  result = server.handle_message({
                                   "jsonrpc" => "2.0",
                                   "id" => 1,
                                   "method" => "tools/call",
                                   "params" => {
                                     "name" => "valid_tool",
                                     "arguments" => { "name" => "Alice", "age" => 30 }
                                   }
                                 }, session, "demo-session")

  puts "   Result: #{result[:content][0][:text]}"
rescue StandardError => e
  puts "   ❌ Error: #{e.message}"
end
puts

# Example 4: Invalid input (wrong type)
puts "✗ Calling tool with invalid arguments (wrong type)..."
begin
  server.handle_message({
                          "jsonrpc" => "2.0",
                          "id" => 2,
                          "method" => "tools/call",
                          "params" => {
                            "name" => "valid_tool",
                            "arguments" => { "name" => 123 } # Should be string, not number
                          }
                        }, session, "demo-session")
rescue VectorMCP::InvalidParamsError => e
  puts "   ❌ Validation failed: #{e.message}"
  puts "   Details: #{e.details[:validation_errors].first}"
end
puts

# Example 5: Invalid input (missing required field)
puts "✗ Calling tool with invalid arguments (missing required field)..."
begin
  server.handle_message({
                          "jsonrpc" => "2.0",
                          "id" => 3,
                          "method" => "tools/call",
                          "params" => {
                            "name" => "valid_tool",
                            "arguments" => { "age" => 25 } # Missing required "name" field
                          }
                        }, session, "demo-session")
rescue VectorMCP::InvalidParamsError => e
  puts "   ❌ Validation failed: #{e.message}"
  puts "   Details: #{e.details[:validation_errors].first}"
end
puts

puts "=== Summary ==="
puts "• Schema Validation: Ensures developers register tools with valid JSON schemas"
puts "• Input Validation: Ensures user arguments match the defined schema requirements"
puts "• Both work together to provide comprehensive security and type safety"
puts "• Tools without schemas continue to work normally (backward compatible)"
puts

puts "Demo completed! Both validation layers are working correctly."
