# VectorMCP Examples

This directory contains example implementations demonstrating various features and use cases of the VectorMCP framework. Each example is designed to be educational and can serve as a starting point for your own MCP server implementations.

## Overview

VectorMCP is a Ruby implementation of the [Model Context Protocol (MCP)](https://modelcontext.dev/), allowing you to create servers that expose tools, resources, prompts, and filesystem roots to LLM clients. These examples showcase different transport mechanisms, security features, and integration patterns.

## Quick Start

All examples can be run directly from the command line. Make sure you have the dependencies installed:

```bash
# Install dependencies
bundle install

# Run any example
ruby examples/stdio_server.rb
ruby examples/http_server.rb
```

## Example Files

### 📡 **Transport Implementations**

#### [`stdio_server.rb`](./stdio_server.rb)
**Basic MCP server using stdin/stdout transport**

A fundamental example demonstrating the core MCP server functionality using the stdio transport. This is the most common transport for process-based MCP servers.

**Features:**
- Echo tool with input validation
- Dynamic resource serving current time
- Prompt template for text analysis
- JSON-RPC over stdin/stdout

**Usage:**
```bash
ruby examples/stdio_server.rb
# Send JSON-RPC messages via stdin
```

**Best for:** Command-line tools, process spawning, direct integration

---

#### [`http_server.rb`](./http_server.rb)
**HTTP server with Server-Sent Events (SSE) transport**

Demonstrates how to run an MCP server over HTTP using Server-Sent Events for real-time communication. Ideal for web-based clients and browser integration.

**Features:**
- HTTP endpoints for MCP communication
- Real-time SSE streaming
- CORS support for browser clients
- Multiple tools and resources

**Usage:**
```bash
ruby examples/http_server.rb
# Server runs on http://localhost:8080
# Connect via SSE at GET /sse
# Send requests to POST /message?session_id=<id>
```

**Best for:** Web applications, browser clients, dashboard integrations

---

### 🔧 **Feature Demonstrations**

#### [`simple_server.rb`](./simple_server.rb)
**Minimal MCP server implementation**

A stripped-down example showing the absolute minimum needed to create a working MCP server. Perfect for understanding the core concepts.

**Features:**
- Single echo tool
- Basic error handling
- Minimal configuration

**Usage:**
```bash
ruby examples/simple_server.rb
```

**Best for:** Learning, prototyping, understanding MCP basics

---

#### [`roots_demo.rb`](./roots_demo.rb) 
**Filesystem roots and security boundaries**

Comprehensive demonstration of the MCP roots feature, showing how to define secure filesystem boundaries for your server operations.

**Features:**
- Multiple root registration
- Security validation and path checking
- Tools that operate within root boundaries
- Workspace context for clients

**Usage:**
```bash
ruby examples/roots_demo.rb
```

**Key concepts:**
- **Root registration**: Define allowed filesystem areas
- **Security boundaries**: Prevent path traversal attacks
- **Workspace context**: Help clients understand available directories
- **Access validation**: Ensure operations stay within bounds

**Best for:** File system tools, code analysis, secure file operations

---

#### [`validation_demo.rb`](./validation_demo.rb) ⭐ **NEW**
**Comprehensive input and schema validation**

Showcases VectorMCP's two-layer validation system that provides both security and developer experience improvements.

**Features:**
- **Schema validation** during tool registration
- **Input validation** during tool execution  
- Error handling and debugging examples
- Security best practices demonstration

**Validation Types:**
1. **Schema Validation** (Registration-time):
   - Validates JSON Schema format during `register_tool()`
   - Catches developer errors early
   - Ensures well-formed schemas

2. **Input Validation** (Runtime):
   - Validates user arguments against defined schemas
   - Prevents injection attacks
   - Provides detailed error messages

**Usage:**
```bash
ruby examples/validation_demo.rb
```

**Best for:** Understanding security features, learning validation patterns, building secure tools

---

### 🖥️ **Client Examples**

#### [`cli_client.rb`](./cli_client.rb)
**Command-line MCP client implementation**

Example client that connects to MCP servers, demonstrating how to integrate VectorMCP into client applications.

**Features:**
- Server connection and session management
- Tool invocation examples
- Resource fetching
- Interactive command-line interface

**Usage:**
```bash
# Connect to local server
ruby examples/cli_client.rb http://localhost:8080/sse

# Connect with custom session ID
ruby examples/cli_client.rb http://localhost:8080/sse my-session-123
```

**Best for:** Building MCP clients, testing servers, automation scripts

---

## Common Patterns

### 🛡️ **Security Best Practices**

```ruby
# Always use input schemas for validation
server.register_tool(
  name: "secure_tool",
  input_schema: {
    type: "object",
    properties: {
      email: { type: "string", format: "email" },
      role: { type: "string", enum: %w[admin user guest] }
    },
    required: ["email"],
    additionalProperties: false
  }
) { |args| process_user(args) }
```

### 🚀 **Transport Selection**

- **Stdio**: Command-line tools, subprocess integration
- **SSE**: Web applications, real-time dashboards, browser clients

### 📁 **Workspace Management**

```ruby
# Define secure filesystem boundaries
server.register_root_from_path("./src", name: "Source Code")
server.register_root_from_path("./docs", name: "Documentation")

# Tools can then operate safely within these bounds
```

### 🔍 **Resource Patterns**

```ruby
# Dynamic resources
server.register_resource(
  uri: "system://status",
  name: "System Status", 
  mime_type: "application/json"
) { |params| { status: "ok", timestamp: Time.now } }
```

## Development Tips

1. **Start Simple**: Begin with `simple_server.rb` or `stdio_server.rb`
2. **Add Validation**: Use `validation_demo.rb` patterns for security
3. **Define Boundaries**: Use `roots_demo.rb` for filesystem operations
4. **Choose Transport**: Stdio for CLI tools, SSE for web integration
5. **Test Thoroughly**: Use the examples as integration test references

## Integration Examples

### With Claude Desktop

```json
{
  "mcpServers": {
    "vector-mcp-example": {
      "command": "ruby",
      "args": ["path/to/examples/stdio_server.rb"]
    }
  }
}
```

### With Web Applications

```javascript
// Connect to SSE endpoint
const eventSource = new EventSource('http://localhost:8080/sse');

eventSource.addEventListener('endpoint', (event) => {
  const { uri } = JSON.parse(event.data);
  // Send MCP requests to the URI
});
```

## Contributing

When adding new examples:

1. **Follow naming conventions**: `feature_demo.rb` or `transport_server.rb`
2. **Include comprehensive comments**: Explain the what and why
3. **Add to this README**: Update with description and usage
4. **Test thoroughly**: Ensure examples work standalone
5. **Follow security patterns**: Always include input validation

## Next Steps

- Explore the [main README](../README.md) for detailed API documentation
- Check out [file_system_mcp](https://github.com/sergiobayona/file_system_mcp) for a real-world implementation
- Read the [MCP specification](https://modelcontext.dev/) for protocol details
- Join the MCP community for questions and contributions