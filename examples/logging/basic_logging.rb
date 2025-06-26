#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../lib/vector_mcp"

puts "=== VectorMCP Enhanced Logging Demo ==="
puts

# Test 1: Legacy compatibility
puts "1. Testing legacy compatibility:"
legacy_logger = VectorMCP.logger
legacy_logger.info("This is legacy logging - still works!")
puts

# Test 2: Basic structured logging
puts "2. Testing structured logging setup:"
VectorMCP.setup_logging(level: "DEBUG", format: "text")

# Test 3: Component-specific loggers
puts "3. Testing component-specific loggers:"
server_logger = VectorMCP.logger_for("server")
transport_logger = VectorMCP.logger_for("transport.stdio")
security_logger = VectorMCP.logger_for("security.auth")

server_logger.info("Server initialized", context: { port: 8080, transport: "stdio" })
transport_logger.debug("Processing request", context: { request_id: "req_123", method: "tools/call" })
security_logger.security("Authentication successful", context: { user_id: "user_456", strategy: "api_key" })
puts

# Test 4: Log levels and filtering
puts "4. Testing log levels:"
server_logger.trace("This is trace level")
server_logger.debug("This is debug level")
server_logger.info("This is info level")
server_logger.warn("This is warn level")
server_logger.error("This is error level")
server_logger.fatal("This is fatal level")
puts

# Test 5: Context management
puts "5. Testing context management:"
server_logger.with_context(session_id: "sess_789") do
  server_logger.info("Processing within session context")
  server_logger.warn("Session warning with context")
end
puts

# Test 6: Performance measurement
puts "6. Testing performance measurement:"
result = server_logger.measure("Database query") do
  sleep(0.1) # Simulate work
  "query result"
end
puts "Result: #{result}"
puts

# Test 7: JSON formatting
puts "7. Testing JSON formatting:"
VectorMCP.configure_logging do
  console format: "json", colorize: false
end

json_logger = VectorMCP.logger_for("json_test")
json_logger.info("This is JSON formatted", context: {
                   nested: { data: "value" },
                   array: [1, 2, 3],
                   timestamp: Time.now
                 })
puts

# Test 8: Configuration from environment
puts "8. Testing environment configuration:"
ENV["VECTORMCP_LOG_LEVEL"] = "WARN"
env_config = VectorMCP::Logging::Configuration.from_env
puts "Environment log level: #{env_config.config[:level]}"
puts

# Test 9: Multiple outputs (if file output works)
puts "9. Testing file output configuration:"
begin
  VectorMCP::Logging::Configuration.new(
    output: "file",
    file: { path: "/tmp/vectormcp_demo.log" },
    format: "json"
  )
  puts "File output configuration created successfully"
rescue StandardError => e
  puts "File output test skipped: #{e.message}"
end
puts

puts "=== Demo completed ==="
puts "Check the various log outputs above to see the enhanced logging in action!"
