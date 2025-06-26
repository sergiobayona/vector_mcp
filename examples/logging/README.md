# 📊 VectorMCP Logging & Observability

This section demonstrates VectorMCP's comprehensive logging system designed for production monitoring, debugging, and security auditing.

## 🎯 What You'll Learn

- **Component-based logging**: Organized, hierarchical log organization
- **Structured output**: JSON format for log aggregation systems
- **Security event tracking**: Authentication, authorization, and audit trails
- **Performance monitoring**: Request timing and operation measurement
- **Log analysis**: Processing and extracting insights from log data

---

## 📚 Examples Overview

### 1. [`basic_logging.rb`](./basic_logging.rb) 📝 **START HERE**
**Component-based logging with context management**

```bash
ruby examples/logging/basic_logging.rb
```

**What it demonstrates:**
- **Component loggers**: Organized logging by functional area
- **Context management**: Structured data with request correlation
- **Performance measurement**: Built-in timing and metrics
- **Multiple log levels**: DEBUG, INFO, WARN, ERROR, FATAL
- **Hierarchical configuration**: Different levels per component

**Key patterns:**
```ruby
# Component-specific loggers
server_logger = VectorMCP.logger_for("server")
transport_logger = VectorMCP.logger_for("transport.sse")
security_logger = VectorMCP.logger_for("security.auth")

# Structured context
server_logger.info("Request processed", context: {
  user_id: "user_123",
  tool_name: "echo",
  duration_ms: 45,
  timestamp: Time.now.iso8601
})

# Performance measurement
result = server_logger.measure("Database query") do
  perform_slow_operation
end
```

**Perfect for:** Development debugging, basic production monitoring

---

### 2. [`structured_logging.rb`](./structured_logging.rb) 🏗️ **PRODUCTION READY**
**JSON output and integration with log aggregation systems**

```bash
# Human-readable format
ruby examples/logging/structured_logging.rb

# JSON format for log aggregation
VECTORMCP_LOG_FORMAT=json ruby examples/logging/structured_logging.rb

# File output
VECTORMCP_LOG_OUTPUT=file VECTORMCP_LOG_FILE_PATH=/tmp/vectormcp.log ruby examples/logging/structured_logging.rb
```

**What it demonstrates:**
- **JSON output format**: Machine-readable logs for Elasticsearch, Splunk, etc.
- **Environment-based configuration**: Flexible deployment options
- **File rotation**: Production log management
- **Correlation IDs**: Request tracking across components
- **Metrics integration**: Ready for Prometheus, DataDog, etc.

**Configuration options:**
```bash
# Environment variables
export VECTORMCP_LOG_LEVEL=INFO
export VECTORMCP_LOG_FORMAT=json
export VECTORMCP_LOG_OUTPUT=file
export VECTORMCP_LOG_FILE_PATH=/var/log/vectormcp.log

# YAML configuration
VectorMCP.configure_logging do
  level "INFO"
  format "json"
  output "console"
  component "security.auth", level: "DEBUG"
  component "transport.sse", level: "WARN"
end
```

**Perfect for:** Production deployments, monitoring integrations, compliance logging

---

### 3. [`security_logging.rb`](./security_logging.rb) 🔐 **SECURITY ESSENTIAL**
**Authentication, authorization, and audit trail implementation**

```bash
ruby examples/logging/security_logging.rb
```

**What it demonstrates:**
- **Authentication events**: Login attempts, failures, token validation
- **Authorization tracking**: Permission checks and access decisions
- **Audit trails**: Complete security event history
- **Threat detection**: Failed login patterns and suspicious activity
- **Compliance logging**: Meeting regulatory requirements

**Security event types:**
```ruby
# Authentication events
security_logger.security("Authentication successful", context: {
  user_id: "user_123",
  strategy: "jwt",
  ip_address: "192.168.1.100",
  user_agent: "Claude Desktop/1.0"
})

# Authorization events  
security_logger.security("Authorization denied", context: {
  user_id: "user_456", 
  resource: "admin_tool",
  reason: "insufficient_permissions",
  requested_action: "execute"
})

# Audit trail
security_logger.audit("Tool executed", context: {
  user_id: "user_123",
  tool_name: "file_delete",
  target_file: "/secure/document.txt",
  timestamp: Time.now.iso8601
})
```

**Perfect for:** Enterprise applications, compliance requirements, security monitoring

---

### 4. [`log_analysis.rb`](./log_analysis.rb) 📈 **INSIGHTS & MONITORING**
**Processing and analyzing VectorMCP log data**

```bash
# Analyze log file
ruby examples/logging/log_analysis.rb /var/log/vectormcp.log

# Real-time analysis
tail -f /var/log/vectormcp.log | ruby examples/logging/log_analysis.rb -
```

**What it demonstrates:**
- **Log parsing**: Processing structured JSON logs
- **Pattern detection**: Identifying security threats and performance issues
- **Metrics extraction**: Converting logs to time-series data
- **Alert generation**: Triggering notifications for critical events
- **Report generation**: Summarizing activity and trends

**Analysis capabilities:**
```ruby
# Performance metrics
analyzer.performance_summary
# => { avg_request_time: 150, p95: 500, errors: 12 }

# Security insights
analyzer.security_threats
# => { failed_logins: 15, suspicious_ips: ["192.168.1.50"] }

# Usage patterns
analyzer.tool_usage
# => { "browser_navigate": 450, "file_read": 230, "echo": 120 }
```

**Perfect for:** Operations teams, security analysts, performance optimization

---

## 🔧 Logging Architecture

### Component Hierarchy
```
VectorMCP Logger
├── server.*              # Core server operations
├── transport.*           # Communication layers
│   ├── transport.stdio   # Stdio transport
│   └── transport.sse     # SSE transport
├── security.*           # Security operations
│   ├── security.auth    # Authentication
│   └── security.authz   # Authorization
├── browser.*           # Browser automation
│   ├── browser.queue   # Command queue
│   └── browser.tools   # Tool execution
└── operations.*        # Business logic
```

### Log Levels
- **DEBUG**: Detailed diagnostic information
- **INFO**: General operational messages
- **WARN**: Warning conditions that should be monitored
- **ERROR**: Error conditions that need attention
- **FATAL**: Critical errors that may cause shutdown

### Output Formats

**Text Format** (Human-readable):
```
[2024-01-15 10:30:45] INFO  server: Request processed (user_id=user_123, duration_ms=45)
[2024-01-15 10:30:46] WARN  security.auth: Invalid API key attempt (ip=192.168.1.50)
```

**JSON Format** (Machine-readable):
```json
{
  "timestamp": "2024-01-15T10:30:45Z",
  "level": "INFO",
  "component": "server",
  "message": "Request processed",
  "context": {
    "user_id": "user_123",
    "duration_ms": 45,
    "request_id": "req_789"
  }
}
```

---

## 🛠️ Production Configuration

### 1. Environment-based Setup
```bash
# Production environment
export VECTORMCP_LOG_LEVEL=INFO
export VECTORMCP_LOG_FORMAT=json
export VECTORMCP_LOG_OUTPUT=file
export VECTORMCP_LOG_FILE_PATH=/var/log/vectormcp/app.log

# Development environment  
export VECTORMCP_LOG_LEVEL=DEBUG
export VECTORMCP_LOG_FORMAT=text
export VECTORMCP_LOG_OUTPUT=console
```

### 2. YAML Configuration
```yaml
# config/logging.yml
logging:
  level: INFO
  format: json
  output: file
  file_path: /var/log/vectormcp.log
  components:
    security.auth:
      level: DEBUG
    transport.sse:
      level: WARN
```

### 3. Programmatic Configuration
```ruby
VectorMCP.configure_logging do
  level "INFO"
  format "json"
  output "file"
  file_path "/var/log/vectormcp.log"
  
  component "security.auth", level: "DEBUG"
  component "transport.sse", level: "WARN"
  
  console colorize: false, include_timestamp: true
end
```

---

## 📊 Monitoring Integration

### Prometheus Metrics
```ruby
# Custom metrics export
prometheus_logger = VectorMCP.logger_for("metrics.prometheus")

prometheus_logger.measure("tool_execution_time") do
  execute_tool(name, arguments)
end

# Counter metrics
prometheus_logger.increment("requests_total", labels: { tool: name })
prometheus_logger.increment("errors_total", labels: { type: "validation" })
```

### ELK Stack Integration
```bash
# Logstash configuration for VectorMCP JSON logs
input {
  file {
    path => "/var/log/vectormcp/*.log"
    codec => "json"
  }
}

filter {
  if [component] =~ /^security/ {
    mutate { add_tag => ["security"] }
  }
}

output {
  elasticsearch {
    hosts => ["localhost:9200"]
    index => "vectormcp-%{+YYYY.MM.dd}"
  }
}
```

---

## 🚀 Best Practices

### 1. Structure Your Context
```ruby
# ✅ Good - Consistent, searchable context
logger.info("User action", context: {
  user_id: session.user_id,
  action: "tool_call",
  tool_name: tool.name,
  duration_ms: timing.duration,
  success: result.success?,
  timestamp: Time.now.iso8601
})

# ❌ Bad - Unstructured, hard to search
logger.info("User #{user} called #{tool} and it took #{time}ms")
```

### 2. Use Appropriate Log Levels
```ruby
# DEBUG - Detailed diagnostic info
logger.debug("Processing request", context: { params: sanitized_params })

# INFO - Normal operations
logger.info("Tool executed successfully", context: { tool: name })

# WARN - Something unusual but not critical
logger.warn("Rate limit approaching", context: { usage: "90%" })

# ERROR - Errors that need attention
logger.error("Tool execution failed", context: { error: e.message })

# FATAL - Critical system errors
logger.fatal("Database connection lost", context: { error: e.message })
```

### 3. Sanitize Sensitive Data
```ruby
def sanitize_for_logging(params)
  sanitized = params.dup
  sensitive_fields = %w[password token secret authorization]
  
  sensitive_fields.each do |field|
    sanitized[field] = "[REDACTED]" if sanitized.key?(field)
  end
  
  sanitized
end
```

---

## 💡 Pro Tips

- **Use component loggers**: Organize logs by functional area for easier debugging
- **Include correlation IDs**: Track requests across multiple components
- **Monitor security events**: Set up alerts for failed authentication attempts
- **Measure performance**: Use the built-in timing capabilities
- **Configure per environment**: Different log levels for dev/staging/production
- **Rotate log files**: Prevent disk space issues in production
- **Parse with tools**: Use jq, grep, and other tools for log analysis

Ready to monitor your VectorMCP servers like a pro? 📈