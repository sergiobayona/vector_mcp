# VectorMCP Structured Logging Overview

This document provides an overview of the comprehensive structured logging capabilities implemented in VectorMCP browser automation.

## 🎯 Logging Architecture

### Component-Based Logging
VectorMCP uses component-based logging to organize events by functional area:

- **`browser.operations`** - Tool execution and HTTP operations
- **`browser.queue`** - Command queue management and extension communication  
- **`security.browser`** - Authentication, authorization, and security events
- **`transport.sse`** - HTTP transport and connection management
- **`server`** - Server lifecycle and configuration events

### Log Formats
- **JSON Format**: Machine-readable structured data for analysis
- **Text Format**: Human-readable colored output for development
- **Multiple Outputs**: Console, files, with component-specific routing

## 📊 Event Types Logged

### 🔍 Browser Operations
```json
{
  "level": "INFO",
  "message": "Browser operation started",
  "component": "browser.operations",
  "context": {
    "operation_id": "uuid-123",
    "endpoint": "navigate", 
    "tool": "Navigate",
    "params": {"url": "https://example.com"},
    "server": "localhost:8000",
    "timestamp": "2024-01-01T12:00:00Z"
  }
}
```

### 🔄 Command Queue Management
```json
{
  "level": "INFO",
  "message": "Commands dispatched to extension",
  "component": "browser.queue",
  "context": {
    "command_count": 3,
    "command_ids": ["uuid-1", "uuid-2", "uuid-3"],
    "actions": ["navigate", "click", "snapshot"],
    "timestamp": "2024-01-01T12:00:00Z"
  }
}
```

### 🔐 Security Events
```json
{
  "level": "INFO", 
  "message": "Browser automation authorized",
  "component": "security.browser",
  "context": {
    "action": "navigate",
    "user_id": "user_123",
    "user_role": "browser_user",
    "ip_address": "127.0.0.1",
    "timestamp": "2024-01-01T12:00:00Z"
  }
}
```

### ⚡ Performance Metrics
```json
{
  "level": "INFO",
  "message": "Browser operation completed", 
  "component": "browser.operations",
  "context": {
    "operation_id": "uuid-123",
    "tool": "Navigate",
    "success": true,
    "execution_time_ms": 1250.45,
    "response_size": 2048,
    "timestamp": "2024-01-01T12:00:00Z"
  }
}
```

## 🛠️ Usage Examples

### Basic Server Setup with Logging
```ruby
# Configure structured logging
VectorMCP.setup_logging(level: "INFO", format: "json")

VectorMCP.configure_logging do
  console colorize: true, include_timestamp: true
  file "/var/log/vectormcp.log", level: "INFO"
  component "browser.operations", level: "DEBUG"
end

# Create server - logging is automatic
server = VectorMCP::Server.new("my-server")
server.register_browser_tools
```

### Log Analysis Commands
```bash
# Real-time monitoring
tail -f /tmp/vectormcp_operations.log | jq

# Filter by component
jq 'select(.component == "browser.operations")' /tmp/vectormcp_operations.log

# Performance analysis
jq 'select(.context.execution_time_ms > 1000)' /tmp/vectormcp_operations.log

# User activity tracking
jq 'select(.context.user_id == "user_123")' /tmp/vectormcp_operations.log

# Error analysis
jq 'select(.level == "ERROR")' /tmp/vectormcp_operations.log
```

### Automated Log Analysis
```ruby
# Use built-in analysis tool
ruby examples/analyze_logs.rb /tmp/vectormcp_operations.log
```

## 🎮 Demo Servers

### Structured Logging Demo
```bash
# Start comprehensive logging demo
ruby examples/structured_logging_demo.rb

# Generate test events
ruby examples/test_structured_logging.rb

# Analyze results
ruby examples/analyze_logs.rb
```

### Security Logging Demo
```bash
# Focus on security events
ruby examples/security_logging_demo.rb

# Test security scenarios
ruby examples/test_security_logging.rb
```

## 📈 Key Metrics Tracked

### Operational Metrics
- **Execution Time**: Per-operation timing in milliseconds
- **Queue Performance**: Command processing and dispatch timing
- **Success Rates**: Operation completion vs failure rates
- **Response Sizes**: Payload sizes for performance analysis

### Security Metrics
- **Authentication Events**: Success/failure rates by strategy
- **Authorization Decisions**: Allow/deny rates by user role  
- **User Activity**: Actions per user, tool usage patterns
- **Security Violations**: Failed access attempts, blocked actions

### System Metrics
- **Extension Connectivity**: Connection/disconnection events
- **Error Rates**: Error frequency by category and component
- **Resource Usage**: Queue sizes, connection counts
- **Component Health**: Activity levels per component

## 🔍 Observability Features

### Real-Time Monitoring
- Live log streaming with `tail -f`
- Component-based filtering
- Level-based alerting (ERROR, WARN)
- Performance threshold monitoring

### Historical Analysis
- JSON log parsing and aggregation
- Time-series performance analysis
- User behavior pattern detection
- Security audit trail reconstruction

### Development Tools
- Colored console output for debugging
- Structured context for error investigation
- Parameter sanitization for security
- Component isolation for focused debugging

## 🛡️ Security Features

### Data Protection
- **Parameter Sanitization**: Sensitive data (passwords, tokens) redacted
- **Text Truncation**: Large payloads truncated to prevent log bloat
- **User Context**: Secure user identification without exposing credentials
- **IP Tracking**: Request source tracking for security analysis

### Audit Compliance
- **Complete Audit Trail**: Every security decision logged
- **Immutable Logs**: JSON format for tamper detection
- **User Attribution**: All actions linked to authenticated users
- **Time Precision**: ISO 8601 timestamps for accurate sequencing

## 🚀 Production Deployment

### Log Management
```ruby
VectorMCP.configure_logging do
  # Separate log files by concern
  file "/var/log/vectormcp/operations.log", 
       level: "INFO", 
       components: ["browser.operations", "browser.queue"]
       
  file "/var/log/vectormcp/security.log",
       level: "WARN",
       components: ["security"]
       
  file "/var/log/vectormcp/errors.log",
       level: "ERROR"
end
```

### Monitoring Integration
- **Log Aggregation**: Ship JSON logs to ELK stack, Splunk, etc.
- **Alerting**: Monitor ERROR/WARN events for incidents
- **Dashboards**: Visualize performance and security metrics
- **Compliance**: Audit trail for security compliance requirements

## 🎯 Benefits

### For Developers
- **Debugging**: Rich context for troubleshooting issues
- **Performance**: Identify slow operations and bottlenecks  
- **Testing**: Verify security policies and business logic
- **Integration**: Understand system behavior during development

### For Operations
- **Monitoring**: Real-time system health and performance
- **Alerting**: Proactive issue detection and response
- **Capacity Planning**: Performance trends and resource usage
- **Incident Response**: Complete audit trail for forensics

### For Security
- **Audit Trail**: Complete record of user actions and decisions
- **Threat Detection**: Identify suspicious patterns and attempts
- **Compliance**: Meet regulatory logging requirements
- **Access Control**: Verify authorization policies are working

### For Business
- **Usage Analytics**: Understand how browser automation is used
- **Performance SLAs**: Track response times and availability  
- **User Behavior**: Analyze patterns for product improvement
- **Risk Management**: Monitor security events and compliance