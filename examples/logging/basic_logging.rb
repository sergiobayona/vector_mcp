#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../../lib/vector_mcp"

puts "=== VectorMCP Simple Logging Demo ==="
puts

# Test 1: Basic logging
puts "1. Testing basic logging:"
logger = VectorMCP.logger
logger.info("This is basic logging!")
puts

# Test 2: Component-specific loggers
puts "2. Testing component-specific loggers:"
server_logger = VectorMCP.logger_for("server")
transport_logger = VectorMCP.logger_for("transport.stdio")
security_logger = VectorMCP.logger_for("security.auth")

server_logger.info("Server initialized", port: 8080, transport: "stdio")
transport_logger.debug("Processing request", request_id: "req_123", method: "tools/call")
security_logger.security("Authentication successful", user_id: "user_456", strategy: "api_key")
puts

# Test 3: Log levels
puts "3. Testing log levels:"
server_logger.debug("This is debug level")
server_logger.info("This is info level")
server_logger.warn("This is warn level")
server_logger.error("This is error level")
server_logger.fatal("This is fatal level")
puts

# Test 4: Performance measurement
puts "4. Testing performance measurement:"
result = server_logger.measure("Database query") do
  sleep(0.1) # Simulate work
  "query result"
end
puts "Result: #{result}"
puts

# Test 5: Environment configuration
puts "5. Testing environment configuration:"
puts "Set VECTORMCP_LOG_LEVEL=DEBUG for debug messages"
puts "Set VECTORMCP_LOG_FORMAT=json for JSON output"
puts "Set VECTORMCP_LOG_OUTPUT=file for file output"
puts

puts "=== Demo completed ==="
puts "Try running with different environment variables:"
puts "VECTORMCP_LOG_FORMAT=json ruby examples/logging/basic_logging.rb"
