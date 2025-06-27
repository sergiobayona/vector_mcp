#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../../lib/vector_mcp"

puts "=== VectorMCP Structured Logging Demo ==="
puts

# Demonstrate structured logging with context
server_logger = VectorMCP.logger_for("server")
request_logger = VectorMCP.logger_for("request.handler")

# Basic structured logging
server_logger.info("Server starting", 
  version: "1.0.0", 
  transport: "stdio", 
  pid: Process.pid
)

# Request processing with context
request_id = "req_#{Time.now.to_i}"
request_logger.info("Processing request", 
  request_id: request_id, 
  method: "tools/call",
  tool_name: "echo",
  start_time: Time.now.iso8601
)

# Performance measurement
result = request_logger.measure("Tool execution", request_id: request_id) do
  sleep(0.05) # Simulate tool work
  { result: "Hello, World!", status: "success" }
end

request_logger.info("Request completed", 
  request_id: request_id,
  result_size: result.to_s.length,
  end_time: Time.now.iso8601
)

puts
puts "Try with JSON format:"
puts "VECTORMCP_LOG_FORMAT=json ruby examples/logging/structured_logging.rb"