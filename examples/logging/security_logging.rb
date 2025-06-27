#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../../lib/vector_mcp"

puts "=== VectorMCP Security Logging Demo ==="
puts

# Create server with security logging
server = VectorMCP::Server.new("security-demo", version: "1.0.0")
security_logger = VectorMCP.logger_for("security")

# Enable authentication with logging
server.enable_authentication!(strategy: :api_key, keys: ["admin-key", "user-key"])

# Log authentication attempts
puts "Simulating authentication events:"

# Simulate successful authentication
security_logger.security("Authentication successful", 
  user_id: "admin_001",
  api_key_type: "admin",
  ip_address: "192.168.1.100",
  timestamp: Time.now.iso8601
)

# Simulate failed authentication
security_logger.security("Authentication failed", 
  reason: "invalid_api_key",
  attempt_count: 3,
  ip_address: "10.0.0.1",
  timestamp: Time.now.iso8601
)

# Simulate authorization events
auth_logger = VectorMCP.logger_for("security.authorization")

auth_logger.warn("Access denied to restricted tool", 
  user_id: "user_001",
  tool_name: "admin_tool", 
  user_role: "user",
  required_role: "admin"
)

puts
puts "Security events logged. Try with JSON format:"
puts "VECTORMCP_LOG_FORMAT=json ruby examples/logging/security_logging.rb"