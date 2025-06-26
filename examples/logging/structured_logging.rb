#!/usr/bin/env ruby
# frozen_string_literal: true

# Structured Logging Demo
# Comprehensive demonstration of VectorMCP's structured logging capabilities

require_relative "../lib/vector_mcp"

# Configure comprehensive structured logging
VectorMCP.setup_logging(level: "DEBUG", format: "json")

# Set up multiple log outputs and component-specific configuration
VectorMCP.configure_logging do
  # Console output with colors for development
  console colorize: true, include_timestamp: true

  # Main operations log
  file "/tmp/vectormcp_operations.log", level: "INFO"

  # Security audit log (separate file)
  file "/tmp/vectormcp_security.log", level: "WARN", components: ["security"]

  # Component-specific logging levels
  component "browser.operations", level: "DEBUG"   # Detailed operation tracking
  component "browser.queue", level: "INFO"         # Command queue management
  component "security.browser", level: "DEBUG"     # Security events
  component "transport.sse", level: "INFO"         # Transport layer events
end

# Create server with structured logging
server = VectorMCP::Server.new("structured-logging-demo", version: "1.0.0")

# Enable security for comprehensive logging demonstration
server.enable_authentication!(strategy: :api_key, keys: %w[
                                demo-full-access-2024
                                demo-limited-access-2024
                              ])

server.enable_authorization! do
  authorize_tools do |user, _action, tool|
    if tool.name.start_with?("browser_")
      case user[:role]
      when "admin", "browser_user"
        true
      when "demo"
        %w[browser_navigate browser_snapshot].include?(tool.name)
      else
        false
      end
    else
      true
    end
  end
end

# Register browser tools with enhanced logging
server.register_browser_tools

# Enhanced authentication with user roles
server.auth_manager.add_custom_auth do |request|
  api_key = request[:headers]["X-API-Key"]

  case api_key
  when "demo-full-access-2024"
    {
      success: true,
      user: {
        id: "demo_user_full",
        name: "Demo User (Full Access)",
        role: "browser_user",
        permissions: ["browser_*"]
      }
    }
  when "demo-limited-access-2024"
    {
      success: true,
      user: {
        id: "demo_user_limited",
        name: "Demo User (Limited Access)",
        role: "demo",
        permissions: %w[browser_navigate browser_snapshot]
      }
    }
  else
    { success: false, error: "Invalid API key" }
  end
end

# Create transport with logging
transport = VectorMCP::Transport::SSE.new(server, port: 8004, host: "0.0.0.0")

puts <<~BANNER
  📊 VectorMCP Structured Logging Demo

  Server: #{server.name} v#{server.version}
  Transport: SSE on http://0.0.0.0:8004

  📋 Logging Components Demonstrated:

  🔍 Operations Logging (browser.operations):
    ✅ Tool execution start/completion
    ✅ HTTP request timing and performance
    ✅ Parameter sanitization for security
    ✅ Error tracking and categorization
    ✅ User context tracking

  🔄 Queue Management (browser.queue):
    ✅ Command queuing and dispatch
    ✅ Extension communication tracking
    ✅ Command completion monitoring
    ✅ Queue size and performance metrics

  🔐 Security Events (security.browser):
    ✅ Authentication attempts and results
    ✅ Authorization decisions
    ✅ Security violations and alerts
    ✅ User activity audit trails

  🌐 Transport Layer (transport.sse):
    ✅ Client connections and disconnections
    ✅ HTTP request routing
    ✅ Session management
    ✅ Protocol compliance monitoring

  📄 Log Outputs:
    - Console: Real-time colored output for development
    - /tmp/vectormcp_operations.log: All operations (JSON format)
    - /tmp/vectormcp_security.log: Security events only

  🔑 Test API Keys:
    - demo-full-access-2024 (Full browser automation access)
    - demo-limited-access-2024 (Limited to navigation and snapshots)

  🧪 Generate Logging Events:
    1. Connect Chrome extension (logs connection events)
    2. Use browser tools (logs operation lifecycle)
    3. Try different API keys (logs security decisions)
    4. Send invalid requests (logs error handling)

  📊 Monitor Logs:
    # Watch all operations
    tail -f /tmp/vectormcp_operations.log | jq
  #{"  "}
    # Security events only
    tail -f /tmp/vectormcp_security.log | jq
  #{"  "}
    # Filter by component
    tail -f /tmp/vectormcp_operations.log | jq 'select(.component == "browser.operations")'
  #{"  "}
    # Filter by user
    tail -f /tmp/vectormcp_operations.log | jq 'select(.context.user_id == "demo_user_full")'
  #{"  "}
    # Performance analysis
    tail -f /tmp/vectormcp_operations.log | jq 'select(.context.execution_time_ms > 1000)'

  🎯 Key Metrics Tracked:
    - Operation execution times
    - Queue processing performance
    - Error rates by category
    - User activity patterns
    - Security event frequency
    - Extension connectivity status

  Press Ctrl+C to stop the server
BANNER

# Enhanced signal handling with logging
Signal.trap("INT") do
  main_logger = VectorMCP.logger_for("server")
  main_logger.info("Server shutdown initiated", context: {
                     reason: "SIGINT",
                     uptime: Process.clock_gettime(Process::CLOCK_MONOTONIC).round(2),
                     timestamp: Time.now.iso8601
                   })
  puts "\n🛑 Shutting down structured logging demo..."
  exit(0)
end

Signal.trap("TERM") do
  main_logger = VectorMCP.logger_for("server")
  main_logger.info("Server shutdown initiated", context: {
                     reason: "SIGTERM",
                     uptime: Process.clock_gettime(Process::CLOCK_MONOTONIC).round(2),
                     timestamp: Time.now.iso8601
                   })
  puts "\n🛑 Shutting down structured logging demo..."
  exit(0)
end

# Log startup with comprehensive context
startup_logger = VectorMCP.logger_for("server")
startup_logger.info("Structured logging demo server starting", context: {
                      server_name: server.name,
                      server_version: server.version,
                      port: 8004,
                      logging_components: [
                        "browser.operations",
                        "browser.queue",
                        "security.browser",
                        "transport.sse"
                      ],
                      log_outputs: [
                        "/tmp/vectormcp_operations.log",
                        "/tmp/vectormcp_security.log",
                        "console"
                      ],
                      security_enabled: server.security_enabled?,
                      timestamp: Time.now.iso8601
                    })

# Start the server
begin
  server.run(transport: transport)
rescue StandardError => e
  startup_logger.error("Server startup failed", context: {
                         error: e.message,
                         error_class: e.class.name,
                         backtrace: e.backtrace[0..5],
                         timestamp: Time.now.iso8601
                       })
  puts "❌ Server failed to start: #{e.message}"
  exit(1)
end
