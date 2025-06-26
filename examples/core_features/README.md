# 🔧 VectorMCP Core Features

This section demonstrates VectorMCP's advanced capabilities including security, validation, filesystem operations, and client implementation patterns.

## 🎯 What You'll Learn

- **Input Validation**: Schema-based security and error prevention
- **Authentication**: API keys, JWT tokens, and custom strategies
- **Authorization**: Role-based access control and permissions
- **Filesystem Security**: Safe file operations with root boundaries
- **Client Implementation**: Building MCP clients that connect to servers

---

## 📚 Examples Overview

### 1. [`input_validation.rb`](./input_validation.rb) 🛡️ **SECURITY ESSENTIAL**
**Comprehensive input and schema validation system**

```bash
ruby examples/core_features/input_validation.rb
```

**What it demonstrates:**
- **Schema validation** during tool registration (catches developer errors)
- **Input validation** during tool execution (prevents attacks)
- Security best practices for user input handling
- Detailed error messages and debugging support
- Prevention of injection attacks and malformed data

**Key security features:**
```ruby
# Schema validation at registration time
register_tool(
  name: "secure_tool",
  input_schema: {
    type: "object",
    properties: {
      email: { type: "string", format: "email" },
      role: { type: "string", enum: %w[admin user guest] }
    },
    required: ["email"],
    additionalProperties: false  # Prevent extra fields
  }
)

# Runtime validation happens automatically
# Invalid inputs are rejected before reaching your code
```

**Perfect for:** Production servers, security-conscious applications, any tool handling user input

---

### 2. [`authentication.rb`](./authentication.rb) 🔐 **PRODUCTION READY**
**API keys, JWT tokens, and custom authentication strategies**

```bash
# API Key authentication
API_KEY=your-secret-key ruby examples/core_features/authentication.rb

# JWT authentication  
JWT_SECRET=your-jwt-secret ruby examples/core_features/authentication.rb jwt

# Custom authentication
ruby examples/core_features/authentication.rb custom
```

**What it demonstrates:**
- **API Key strategy**: Simple header-based authentication
- **JWT token strategy**: Stateless authentication with claims
- **Custom strategy**: Flexible authentication for complex scenarios
- **Authorization policies**: Role-based access control
- **Security middleware**: Request processing and session management

**Authentication strategies:**
```ruby
# API Key - Simple and effective
server.enable_authentication!(strategy: :api_key, keys: ["secret-key"])

# JWT - Stateless and scalable
server.enable_authentication!(strategy: :jwt_token, secret: "jwt-secret")

# Custom - Maximum flexibility
server.enable_authentication!(strategy: :custom) do |request|
  api_key = request[:headers]["X-API-Key"]
  authenticate_user(api_key)  # Your custom logic
end
```

**Perfect for:** Multi-tenant applications, enterprise integrations, production deployments

---

### 3. [`filesystem_roots.rb`](./filesystem_roots.rb) 📁 **FILE SECURITY**
**Secure file operations with boundary enforcement**

```bash
ruby examples/core_features/filesystem_roots.rb
```

**What it demonstrates:**
- **Root registration**: Define allowed filesystem areas
- **Security boundaries**: Prevent path traversal attacks
- **Workspace context**: Help clients understand available directories
- **Access validation**: Ensure operations stay within bounds
- **File operation tools**: Safe reading, writing, and listing

**Security boundaries:**
```ruby
# Define secure filesystem areas
server.register_root_from_path("./src", name: "Source Code")
server.register_root_from_path("./docs", name: "Documentation")

# Tools automatically respect these boundaries
# Attempts to access ../../../etc/passwd will be blocked
```

**Perfect for:** Code analysis tools, file management systems, documentation generators

---

### 4. [`cli_client.rb`](./cli_client.rb) 🖥️ **CLIENT REFERENCE**
**Complete MCP client implementation**

```bash
# Connect to HTTP server
ruby examples/core_features/cli_client.rb http://localhost:8080/sse

# Connect with custom session
ruby examples/core_features/cli_client.rb http://localhost:8080/sse my-session-id
```

**What it demonstrates:**
- **Server connection**: SSE transport client implementation
- **Session management**: Handling connection state and errors
- **Tool invocation**: Calling server tools with parameters
- **Resource fetching**: Retrieving dynamic content
- **Interactive CLI**: User-friendly command interface

**Client patterns:**
```ruby
# Initialize client
client = MCPClient.new("http://localhost:8080/sse")

# List available tools
tools = client.list_tools

# Call a tool
result = client.call_tool("echo", { "text" => "Hello World" })

# Fetch a resource
content = client.get_resource("file://example.txt")
```

**Perfect for:** Building custom MCP clients, testing servers, automation scripts

---

## 🔒 Security Best Practices

### 1. Always Validate Input
```ruby
# ✅ Good - Comprehensive validation
register_tool(
  name: "safe_tool",
  input_schema: {
    type: "object",
    properties: {
      data: { type: "string", maxLength: 1000 },
      action: { type: "string", enum: %w[read write delete] }
    },
    required: ["data", "action"],
    additionalProperties: false
  }
)

# ❌ Bad - No validation
register_tool(name: "unsafe_tool") { |args| execute(args) }
```

### 2. Enable Authentication
```ruby
# Choose appropriate strategy for your use case
server.enable_authentication!(strategy: :api_key, keys: ["secure-key"])
server.enable_authorization! do
  authorize_tools do |user, action, tool|
    user[:role] == "admin" || !tool.name.include?("admin")
  end
end
```

### 3. Use Filesystem Roots
```ruby
# Define boundaries before registering file tools
server.register_root_from_path("./allowed/directory")
# File operations will be restricted to this area
```

---

## 🛠️ Development Patterns

### Error Handling
```ruby
register_tool(name: "robust_tool") do |arguments|
  begin
    result = process_data(arguments["data"])
    { success: true, result: result }
  rescue ValidationError => e
    { success: false, error: "Invalid input: #{e.message}" }
  rescue StandardError => e
    { success: false, error: "Processing failed: #{e.message}" }
  end
end
```

### Logging Integration
```ruby
register_tool(name: "logged_tool") do |arguments|
  logger.info("Tool called", context: { 
    tool: "logged_tool", 
    user: session_context&.user&.[](:id) 
  })
  
  result = process_request(arguments)
  
  logger.info("Tool completed", context: { 
    success: result[:success],
    duration: measure_time 
  })
  
  result
end
```

### Resource Patterns
```ruby
# Static resource
server.register_resource(
  uri: "config://settings",
  name: "Configuration",
  mime_type: "application/json"
) { load_config.to_json }

# Dynamic resource with parameters
server.register_resource(
  uri: "data://user/{id}",
  name: "User Data",
  mime_type: "application/json"
) do |params|
  user = find_user(params["id"])
  user.to_json
end
```

---

## 🚀 Next Steps

After mastering these core features:

1. **Production Logging** → [`logging/structured_logging.rb`](../logging/structured_logging.rb)
2. **Browser Automation** → [`browser_automation/basic_browser_server.rb`](../browser_automation/basic_browser_server.rb)
3. **Real-World Applications** → [`use_cases/file_operations.rb`](../use_cases/file_operations.rb)

---

## 🤔 Common Questions

**Q: Do I need authentication for development?**
A: Not required, but recommended to understand security patterns early.

**Q: How strict should input validation be?**
A: Very strict! Reject any input that doesn't match your exact requirements.

**Q: Can I combine multiple authentication strategies?**
A: Not directly, but you can implement a custom strategy that handles multiple methods.

**Q: What's the difference between tools and resources?**
A: Tools are functions LLMs can call, resources are data they can read.

**Q: How do I debug authentication issues?**
A: Enable debug logging and check the security event logs.

---

## 💡 Pro Tips

- **Start with validation**: Build the `input_validation.rb` patterns into your tools from day one
- **Test authentication**: Use the CLI client to verify your auth flows work correctly  
- **Secure file access**: Always use filesystem roots for any file operations
- **Log security events**: Track authentication attempts and authorization failures
- **Fail securely**: When in doubt, deny access rather than allow it

Ready to build secure, production-ready MCP servers? 🔒