# VectorMCP Security Guide

VectorMCP provides comprehensive, opt-in security features for Model Context Protocol (MCP) servers. This guide covers authentication strategies, authorization policies, and security best practices.

## Table of Contents

- [Overview](#overview)
- [Quick Start](#quick-start)
- [Authentication Strategies](#authentication-strategies)
- [Authorization Framework](#authorization-framework)
- [Transport Integration](#transport-integration)
- [Advanced Features](#advanced-features)
- [Best Practices](#best-practices)
- [Examples](#examples)
- [Troubleshooting](#troubleshooting)

## Overview

VectorMCP's security system follows an **opt-in design philosophy** - servers run without authentication or authorization by default, and you explicitly enable security features as needed.

### Core Components

- **Authentication Manager**: Manages authentication strategies and user verification
- **Authorization System**: Controls access to tools, resources, prompts, and roots
- **Security Middleware**: Integrates security into request processing pipeline
- **Session Context**: Tracks user state and permissions throughout requests

### Security Philosophy

```ruby
# By default, no security - maximum compatibility
server = VectorMCP::Server.new(name: "MyServer", version: "1.0.0")
server.run  # No authentication or authorization

# Opt-in to security features as needed
server.enable_authentication!(strategy: :api_key, keys: ["secret-key"])
server.enable_authorization! do
  authorize_tools { |user, action, tool| user[:role] == "admin" }
end
```

## Quick Start

### Basic API Key Authentication

```ruby
require "vector_mcp"

server = VectorMCP::Server.new(name: "SecureServer", version: "1.0.0")

# Enable API key authentication
server.enable_authentication!(
  strategy: :api_key,
  keys: ["your-secret-api-key", "another-valid-key"]
)

# Register a protected tool
server.register_tool(
  name: "secure_operation",
  description: "A tool that requires authentication",
  input_schema: { type: "object", properties: { message: { type: "string" } } }
) do |args|
  "Authenticated user accessed: #{args['message']}"
end

server.run(transport: :stdio)
```

**Client Usage:**
```bash
# Include API key in headers
curl -H "X-API-Key: your-secret-api-key" -X POST http://localhost:3000/message
```

### Basic Authorization

```ruby
server.enable_authentication!(strategy: :api_key, keys: ["admin-key", "user-key"])

server.enable_authorization! do
  authorize_tools do |user, action, tool|
    case tool.name
    when "admin_tool"
      user[:api_key] == "admin-key"  # Only admin key can access
    when "user_tool"
      ["admin-key", "user-key"].include?(user[:api_key])  # Both can access
    else
      true  # All authenticated users can access other tools
    end
  end
end
```

## Authentication Strategies

### API Key Authentication

The simplest authentication method using pre-shared keys.

```ruby
# Single key
server.enable_authentication!(
  strategy: :api_key,
  keys: ["my-secret-key"]
)

# Multiple keys for different users/services
server.enable_authentication!(
  strategy: :api_key,
  keys: [
    "service-a-key",
    "service-b-key", 
    "admin-master-key"
  ]
)
```

**Client Headers:**
```
X-API-Key: my-secret-key
# or
Authorization: Bearer my-secret-key
```

**Query Parameters:**
```
GET /sse?api_key=my-secret-key
POST /message?session_id=123&api_key=my-secret-key
```

### JWT Token Authentication

For more sophisticated authentication with claims and expiration.

```ruby
server.enable_authentication!(
  strategy: :jwt,
  secret: ENV["JWT_SECRET"],
  algorithm: "HS256"  # Optional, defaults to HS256
)
```

**JWT Claims:**
```ruby
# Server will extract these claims and make them available in session context
payload = {
  user_id: "123",
  email: "user@example.com",
  role: "admin",
  exp: Time.now.to_i + 3600  # 1 hour expiration
}

token = JWT.encode(payload, ENV["JWT_SECRET"], "HS256")
```

**Client Usage:**
```
Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJ1c2VyX2lkIjoiMTIzIn0...
```

### Custom Authentication

For complex authentication logic or integration with external systems.

```ruby
server.enable_authentication!(strategy: :custom) do |request|
  api_key = request[:headers]["X-API-Key"]
  
  # Custom validation logic
  user = authenticate_with_database(api_key)
  
  if user
    # Return user data on success
    {
      user_id: user.id,
      email: user.email,
      role: user.role,
      permissions: user.permissions
    }
  else
    false  # Authentication failed
  end
end
```

**Advanced Custom Authentication:**

```ruby
server.enable_authentication!(strategy: :custom) do |request|
  # Multiple authentication methods
  if token = request[:headers]["Authorization"]&.sub(/^Bearer /, "")
    validate_oauth_token(token)
  elsif api_key = request[:headers]["X-API-Key"]
    validate_api_key(api_key)
  elsif session_id = request[:params]["session_id"]
    validate_session(session_id)
  else
    false
  end
end

def validate_oauth_token(token)
  # OAuth validation logic
  payload = JWT.decode(token, oauth_public_key, true, algorithm: 'RS256')
  { user_id: payload["sub"], provider: "oauth" }
rescue JWT::DecodeError
  false
end

def validate_api_key(key)
  user = User.find_by(api_key: key)
  user ? { user_id: user.id, provider: "api_key" } : false
end
```

## Authorization Framework

### Policy-Based Authorization

Define fine-grained access control policies for different resource types.

```ruby
server.enable_authorization! do
  # Tool authorization
  authorize_tools do |user, action, tool|
    case user[:role]
    when "admin"
      true  # Admins can access all tools
    when "user"
      !tool.name.start_with?("admin_")  # Users can't access admin tools
    when "readonly"
      action == :list  # Readonly users can only list tools
    else
      false
    end
  end
  
  # Resource authorization  
  authorize_resources do |user, action, resource|
    case action
    when :read
      true  # Everyone can read resources
    when :write, :delete
      user[:role] == "admin"  # Only admins can modify
    end
  end
  
  # Prompt authorization
  authorize_prompts do |user, action, prompt|
    # Check if user has access to this specific prompt
    user[:allowed_prompts]&.include?(prompt.name)
  end
end
```

### Resource-Specific Policies

```ruby
server.enable_authorization! do
  authorize_tools do |user, action, tool|
    case tool.name
    when "file_read"
      user[:permissions]&.include?("file:read")
    when "file_write"
      user[:permissions]&.include?("file:write")
    when "database_query"
      user[:permissions]&.include?("db:read")
    when "user_management"
      user[:role] == "admin"
    else
      true  # Allow access to unlisted tools
    end
  end
end
```

### Session Context Usage

Access user information and manage permissions within your tools:

```ruby
server.register_tool(
  name: "user_info",
  description: "Get current user information",
  input_schema: { type: "object" }
) do |args, session_context|
  # Access user data
  user_id = session_context.user_identifier
  authenticated = session_context.authenticated?
  
  # Check permissions
  if session_context.can_access?(:read, :user_data)
    {
      user_id: user_id,
      authenticated: authenticated,
      permissions: session_context.permissions.to_a
    }
  else
    { error: "Insufficient permissions" }
  end
end
```

## Transport Integration

### Stdio Transport

Security works seamlessly with stdio transport through request headers simulation:

```ruby
server.enable_authentication!(strategy: :api_key, keys: ["key123"])
server.run(transport: :stdio)
```

**Request Processing:**
```json
{
  "method": "tools/call",
  "params": {
    "name": "my_tool",
    "arguments": { "message": "hello" }
  },
  "headers": {
    "X-API-Key": "key123"
  }
}
```

### SSE Transport

Full HTTP header and query parameter support:

```ruby
server.enable_authentication!(strategy: :api_key, keys: ["key123"])
server.run(transport: :sse, host: "localhost", port: 3000)
```

**Client Connection:**
```bash
# Connect with API key in header
curl -H "X-API-Key: key123" http://localhost:3000/sse

# Or in query parameter
curl http://localhost:3000/sse?api_key=key123
```

## Advanced Features

### Security Middleware

The security middleware handles the complete authentication and authorization pipeline:

```ruby
# Manual middleware usage for custom scenarios
result = server.security_middleware.process_request(
  request,
  action: :call,
  resource: tool
)

if result[:success]
  # Access granted
  session_context = result[:session_context]
  # Process request
else
  # Access denied
  error_code = result[:error_code]  # "AUTHENTICATION_REQUIRED" or "AUTHORIZATION_FAILED"
  error_message = result[:error]
end
```

### Session Context Management

```ruby
# Create session contexts manually
authenticated_session = VectorMCP::Security::SessionContext.new(
  user: { id: 123, role: "admin" },
  authenticated: true,
  auth_strategy: "api_key"
)

# Add permissions
authenticated_session.add_permission("file:read")
authenticated_session.add_permission("file:write")

# Check permissions
if authenticated_session.can?("file:read")
  # Allow file reading
end

# Get user identifier for logging
logger.info("User #{authenticated_session.user_identifier} accessed file")
```

### Error Handling

```ruby
server.enable_authentication!(strategy: :custom) do |request|
  begin
    # Your authentication logic
    external_auth_service.validate(request[:headers]["Authorization"])
  rescue AuthService::NetworkError
    # Network issues - deny access for security
    false
  rescue AuthService::InvalidToken
    # Invalid token - deny access
    false
  rescue StandardError => e
    # Log error and deny access
    logger.error("Authentication error: #{e.message}")
    false
  end
end
```

## Best Practices

### 1. Principle of Least Privilege

```ruby
# Grant minimal permissions needed
server.enable_authorization! do
  authorize_tools do |user, action, tool|
    # Start with deny-all, explicitly allow what's needed
    allowed_tools = user[:allowed_tools] || []
    allowed_tools.include?(tool.name)
  end
end
```

### 2. Secure Key Management

```ruby
# Use environment variables for secrets
server.enable_authentication!(
  strategy: :jwt,
  secret: ENV.fetch("JWT_SECRET") { raise "JWT_SECRET not set" }
)

# Rotate API keys regularly
api_keys = [
  ENV["PRIMARY_API_KEY"],
  ENV["SECONDARY_API_KEY"]  # Keep old key during rotation
].compact

server.enable_authentication!(strategy: :api_key, keys: api_keys)
```

### 3. Comprehensive Logging

```ruby
server.enable_authentication!(strategy: :custom) do |request|
  api_key = request[:headers]["X-API-Key"]
  
  if user = authenticate_user(api_key)
    logger.info("Authentication successful for user #{user[:id]}")
    user
  else
    logger.warn("Authentication failed for API key: #{api_key&.slice(0, 8)}...")
    false
  end
end
```

### 4. Graceful Degradation

```ruby
# Provide helpful error messages
server.enable_authorization! do
  authorize_tools do |user, action, tool|
    unless user[:role] == "admin"
      # Log the authorization attempt for audit
      logger.info("User #{user[:id]} attempted to access admin tool #{tool.name}")
      false
    else
      true
    end
  end
end
```

## Examples

### Multi-Tenant SaaS Application

```ruby
server.enable_authentication!(strategy: :jwt, secret: ENV["JWT_SECRET"])

server.enable_authorization! do
  authorize_tools do |user, action, tool|
    tenant_id = user[:tenant_id]
    
    case tool.name
    when "list_users"
      # Users can only see users in their tenant
      tool.configure_scope(tenant_id: tenant_id)
      true
    when "billing_info"
      # Only billing admin role can access billing
      user[:role] == "billing_admin" && user[:tenant_id] == tenant_id
    when "tenant_settings"
      # Tenant admins can modify settings
      user[:role] == "tenant_admin" && user[:tenant_id] == tenant_id
    else
      user[:tenant_id] == tenant_id  # Basic tenant isolation
    end
  end
  
  authorize_resources do |user, action, resource|
    # Check if resource belongs to user's tenant
    resource.tenant_id == user[:tenant_id]
  end
end
```

### API Gateway Integration

```ruby
server.enable_authentication!(strategy: :custom) do |request|
  # Extract user info from API gateway headers
  user_id = request[:headers]["X-Gateway-User-Id"]
  user_role = request[:headers]["X-Gateway-User-Role"]
  tenant_id = request[:headers]["X-Gateway-Tenant-Id"]
  
  if user_id && user_role
    {
      user_id: user_id,
      role: user_role,
      tenant_id: tenant_id,
      source: "api_gateway"
    }
  else
    false
  end
end
```

### Development vs Production

```ruby
if ENV["RAILS_ENV"] == "development"
  # Relaxed security for development
  server.enable_authentication!(
    strategy: :api_key,
    keys: ["dev-key-123"]
  )
else
  # Strict security for production
  server.enable_authentication!(
    strategy: :jwt,
    secret: ENV.fetch("JWT_SECRET"),
    algorithm: "RS256"  # Asymmetric for production
  )
  
  server.enable_authorization! do
    authorize_tools do |user, action, tool|
      # Strict role-based access in production
      required_role = tool.metadata[:required_role] || "user"
      user_roles = user[:roles] || []
      user_roles.include?(required_role)
    end
  end
end
```

## Troubleshooting

### Common Issues

#### 1. Authentication Always Fails

```ruby
# Check if authentication is properly enabled
server.enable_authentication!(strategy: :api_key, keys: ["test-key"])

# Verify the key format in requests
# Correct: "X-API-Key: test-key"
# Incorrect: "X-Api-Key: test-key" (wrong case)
```

#### 2. Authorization Policies Not Working

```ruby
# Ensure authorization is enabled AND authentication is working
server.enable_authentication!(strategy: :api_key, keys: ["key"])
server.enable_authorization! do  # This line is required
  authorize_tools { |user, action, tool| true }
end

# Check that your policy returns a boolean
authorize_tools do |user, action, tool|
  result = user[:role] == "admin"
  puts "Policy result: #{result}"  # Debug output
  result
end
```

#### 3. Session Context is Nil

```ruby
# Make sure to pass session_context to your tool handlers
server.register_tool(name: "test", description: "Test", input_schema: {}) do |args, session_context|
  if session_context
    # Use session_context here
  else
    # session_context will be nil if not provided by transport
  end
end
```

### Debugging Tips

#### Enable Debug Logging

```ruby
# Enable detailed security logging
VectorMCP.logger.level = Logger::DEBUG

# This will show:
# - Authentication attempts and results
# - Authorization policy evaluations
# - Request normalization details
# - Session context creation
```

#### Test Security Configuration

```ruby
# Test authentication manually
auth_result = server.auth_manager.authenticate({
  headers: { "X-API-Key" => "your-key" }
})
puts "Auth result: #{auth_result}"

# Test authorization manually
session_context = VectorMCP::Security::SessionContext.new(
  user: { id: 123, role: "user" },
  authenticated: true
)

authorized = server.authorization.authorize(
  session_context.user,
  :call,
  tool
)
puts "Authorized: #{authorized}"
```

#### Check Security Status

```ruby
# Get current security configuration
status = server.security_status
puts JSON.pretty_generate(status)

# Output example:
# {
#   "authentication": {
#     "enabled": true,
#     "strategies": ["api_key"],
#     "default_strategy": "api_key"
#   },
#   "authorization": {
#     "enabled": true,
#     "policy_types": ["tool"]
#   }
# }
```

### Security Considerations

1. **Never Log Sensitive Data**: Avoid logging API keys, tokens, or user passwords
2. **Use HTTPS**: Always use HTTPS in production for transport encryption
3. **Validate Inputs**: Sanitize and validate all inputs in authorization policies
4. **Monitor Access**: Log authentication and authorization events for audit trails
5. **Regular Updates**: Keep dependencies updated for security patches
6. **Rate Limiting**: Consider implementing rate limiting to prevent brute force attacks

---

For more examples and advanced usage patterns, see the `examples/` directory in the VectorMCP repository.