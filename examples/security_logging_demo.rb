#!/usr/bin/env ruby
# frozen_string_literal: true

# Security Logging Demo
# Demonstrates comprehensive security logging for browser automation

require_relative "../lib/vector_mcp"

# Configure structured logging for security events
VectorMCP.setup_logging(level: "DEBUG", format: "json")

# Enable security-specific logging
VectorMCP.configure_logging do
  # Console output with timestamps and colors for development
  console colorize: true, include_timestamp: true
  
  # File output for security audit logs
  file "/tmp/vectormcp_security.log", level: "INFO"
  
  # Security component logging
  component "security", level: "DEBUG"
  component "security.browser", level: "DEBUG"
  component "security.auth", level: "DEBUG"
end

# Create server with comprehensive security
server = VectorMCP::Server.new("security-logging-demo", version: "1.0.0")

# Enable authentication with multiple user types
api_keys = [
  "admin-secure-key-2024",
  "browser-user-key-2024",
  "demo-limited-key-2024",
  "malicious-key-blocked"  # This will be blocked by authorization
]
server.enable_authentication!(strategy: :api_key, keys: api_keys)

# Enable authorization
server.enable_authorization!

# Register browser automation tools
server.register_browser_tools

# Configure detailed browser authorization with logging
server.enable_browser_authorization! do
  # Admin users get full access
  admin_full_access
  
  # Browser users get full browser access
  browser_user_full_access
  
  # Demo users get limited access
  demo_user_limited_access
  
  # Custom logging for authorization decisions
  allow_navigation do |user, action, tool|
    security_logger = VectorMCP.logger_for("security.browser")
    
    allowed = %w[admin browser_user demo].include?(user[:role])
    
    security_logger.info("Navigation authorization decision", context: {
      user_id: user[:id],
      user_role: user[:role],
      action: action,
      tool: tool.name,
      decision: allowed ? "ALLOW" : "DENY",
      timestamp: Time.now.iso8601
    })
    
    allowed
  end
end

# Enhanced authentication with detailed user context and security logging
server.auth_manager.add_custom_auth do |request|
  security_logger = VectorMCP.logger_for("security.auth")
  api_key = request[:headers]["X-API-Key"]
  
  # Log authentication attempt
  security_logger.info("Authentication attempt", context: {
    api_key_present: !api_key.nil?,
    api_key_length: api_key&.length,
    ip_address: request[:headers]["X-Forwarded-For"] || "unknown",
    user_agent: request[:headers]["User-Agent"] || "unknown",
    timestamp: Time.now.iso8601
  })
  
  result = case api_key
           when "admin-secure-key-2024"
             {
               success: true,
               user: {
                 id: "admin_001",
                 name: "Security Administrator",
                 role: "admin",
                 permissions: ["*"],
                 security_level: "high",
                 last_login: Time.now.iso8601
               }
             }
           when "browser-user-key-2024"
             {
               success: true,
               user: {
                 id: "browser_user_001",
                 name: "Browser Automation Specialist",
                 role: "browser_user",
                 permissions: [
                   "browser_navigate", "browser_click", "browser_type",
                   "browser_snapshot", "browser_screenshot", "browser_console"
                 ],
                 security_level: "medium",
                 last_login: Time.now.iso8601
               }
             }
           when "demo-limited-key-2024"
             {
               success: true,
               user: {
                 id: "demo_user_001",
                 name: "Demo User",
                 role: "demo",
                 permissions: ["browser_navigate", "browser_snapshot"],
                 security_level: "low",
                 access_restrictions: ["read_only"],
                 last_login: Time.now.iso8601
               }
             }
           when "malicious-key-blocked"
             # Simulate blocked/suspicious key
             security_logger.warn("Blocked authentication attempt", context: {
               api_key: "[REDACTED]",
               reason: "suspicious_key",
               ip_address: request[:headers]["X-Forwarded-For"] || "unknown",
               user_agent: request[:headers]["User-Agent"] || "unknown",
               timestamp: Time.now.iso8601
             })
             {
               success: false,
               error: "Access denied - suspicious activity detected"
             }
           else
             {
               success: false,
               error: "Invalid API key"
             }
           end
  
  # Log authentication result
  if result[:success]
    security_logger.info("Authentication successful", context: {
      user_id: result[:user][:id],
      user_role: result[:user][:role],
      security_level: result[:user][:security_level],
      permissions_count: result[:user][:permissions].length,
      timestamp: Time.now.iso8601
    })
  else
    security_logger.warn("Authentication failed", context: {
      error: result[:error],
      api_key_provided: !api_key.nil?,
      timestamp: Time.now.iso8601
    })
  end
  
  result
end

# Create transport with security logging
transport = VectorMCP::Transport::SSE.new(server, port: 8002, host: "0.0.0.0")

puts <<~BANNER
  🔐 Security Logging Demo Server
  
  Server: #{server.name} v#{server.version}
  Transport: SSE on http://0.0.0.0:8002
  
  📊 Security Logging Features:
  ✅ Authentication event logging
  ✅ Authorization decision logging  
  ✅ Browser command execution logging
  ✅ Extension connection/disconnection logging
  ✅ Failed request logging
  ✅ User context tracking
  ✅ Parameter sanitization
  ✅ Performance metrics
  ✅ IP address and user agent tracking
  
  🔑 Test API Keys:
    - admin-secure-key-2024 (Admin - full access)
    - browser-user-key-2024 (Browser User - browser tools)
    - demo-limited-key-2024 (Demo - limited access)
    - malicious-key-blocked (Blocked - security test)
  
  📄 Log Outputs:
    - Console: Colored, timestamped logs for development
    - File: /tmp/vectormcp_security.log (JSON format for analysis)
    - Component-based: Different log levels per security component
  
  🧪 Test Security Logging:
    1. Run: ruby examples/test_browser_authorization.rb
    2. Use different API keys to see various security events
    3. Monitor logs: tail -f /tmp/vectormcp_security.log | jq
    4. Try invalid authentication to see security alerts
  
  🌐 Monitored Endpoints:
    - Authentication: All requests require valid API key
    - Authorization: Role-based access to browser commands  
    - Command Execution: Full audit trail of browser actions
    - Extension Events: Connection/disconnection monitoring
  
  📈 Security Metrics Logged:
    - Authentication success/failure rates
    - Authorization decision outcomes
    - Command execution timing
    - User activity patterns
    - Failed access attempts
    - Extension connectivity status
  
  Press Ctrl+C to stop the server
BANNER

# Signal handling
Signal.trap("INT") do
  security_logger = VectorMCP.logger_for("security")
  security_logger.info("Security logging demo server shutdown", context: {
    reason: "SIGINT",
    uptime_seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC).to_i,
    timestamp: Time.now.iso8601
  })
  puts "\n🛑 Shutting down security logging demo..."
  exit(0)
end

Signal.trap("TERM") do
  security_logger = VectorMCP.logger_for("security")
  security_logger.info("Security logging demo server shutdown", context: {
    reason: "SIGTERM", 
    uptime_seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC).to_i,
    timestamp: Time.now.iso8601
  })
  puts "\n🛑 Shutting down security logging demo..."
  exit(0)
end

# Log server startup
security_logger = VectorMCP.logger_for("security")
security_logger.info("Security logging demo server starting", context: {
  server_name: server.name,
  server_version: server.version,
  port: 8002,
  security_features: {
    authentication: "enabled",
    authorization: "enabled", 
    browser_logging: "enabled",
    audit_trail: "enabled"
  },
  log_outputs: ["console", "file"],
  timestamp: Time.now.iso8601
})

# Start the server
begin
  server.run(transport: transport)
rescue StandardError => e
  security_logger.error("Security demo server startup failed", context: {
    error: e.message,
    backtrace: e.backtrace[0..5],
    timestamp: Time.now.iso8601
  })
  puts "❌ Server failed to start: #{e.message}"
  exit(1)
end