# 🚀 Getting Started with VectorMCP

Welcome to VectorMCP! This section contains simple, beginner-friendly examples to help you understand the basics and get your first MCP server running.

## 🎯 What You'll Learn

- **MCP Protocol Basics**: Understanding JSON-RPC communication
- **Server Setup**: Creating and configuring MCP servers
- **Transport Options**: Using HTTP Stream and HTTP/SSE transports
- **Tool Registration**: Adding functions that LLMs can call
- **Resource Serving**: Providing data to LLM clients

---

## 📚 Examples Overview

### 1. [`minimal_server.rb`](./minimal_server.rb) ⭐ **START HERE**
**The simplest possible MCP server in just a few lines of code**

```bash
ruby examples/getting_started/minimal_server.rb
```

**What it demonstrates:**
- Basic server creation and configuration
- Simple tool registration with echo functionality
- JSON-RPC message handling
- Minimal error handling

**Perfect for:** First-time users who want to see MCP in action immediately

---

### 2. [`basic_http_server.rb`](./basic_http_server.rb)
**Web-based integration using HTTP and Server-Sent Events**

```bash
ruby examples/getting_started/basic_http_server.rb
# Server runs on http://localhost:8080
```

**What it demonstrates:**
- HTTP/SSE transport for web integration
- Real-time bidirectional communication
- Session management
- CORS support for browser clients
- Multiple concurrent client handling

**Perfect for:** Web applications, browser integration, dashboard tools

**Client connection:**
```javascript
// Connect from browser or web app
const eventSource = new EventSource('http://localhost:8080/sse');
```

---

## 🛠️ Development Workflow

### 1. Start Your Server

**HTTP Stream** (recommended):
```bash
ruby examples/getting_started/basic_http_stream_server.rb
```

**HTTP/SSE** (deprecated):
```bash
ruby examples/getting_started/basic_http_server.rb
```

### 2. Test Your Server

```bash
# In another terminal
ruby examples/core_features/cli_client.rb http://localhost:8080/sse
```

### 3. Extend Your Server

Add more tools, resources, or prompts by following the patterns in these examples.

---

## 🧠 Key Concepts

### Tools
Functions that LLMs can call to perform actions:
```ruby
server.register_tool(
  name: "echo",
  description: "Echo back the input",
  input_schema: { 
    type: "object",
    properties: { text: { type: "string" } }
  }
) do |arguments|
  { echo: arguments["text"] }
end
```

### Resources
Data sources that LLMs can read:
```ruby
server.register_resource(
  uri: "time://current",
  name: "Current Time",
  mime_type: "text/plain"
) do
  Time.now.strftime("%Y-%m-%d %H:%M:%S")
end
```

### Prompts
Template conversations for LLMs:
```ruby
server.register_prompt(
  name: "analyze",
  description: "Analyze text"
) do |arguments|
  {
    messages: [
      { role: "user", content: "Analyze: #{arguments['text']}" }
    ]
  }
end
```

---

## 🚀 Next Steps

Once you've mastered these basics:

1. **Add Security** → [`core_features/authentication.rb`](../core_features/authentication.rb)
2. **Validate Inputs** → [`core_features/input_validation.rb`](../core_features/input_validation.rb)
3. **File Operations** → [`core_features/filesystem_roots.rb`](../core_features/filesystem_roots.rb)
4. **Production Logging** → [`logging/structured_logging.rb`](../logging/structured_logging.rb)
5. **Browser Automation** → [`browser_automation/basic_browser_server.rb`](../browser_automation/basic_browser_server.rb)

---

## 💡 Pro Tips

- **Start minimal**: Use `minimal_server.rb` to understand core concepts
- **Add validation**: Always include input schemas for security
- **Use HTTP Stream transport**: The default and recommended transport for all use cases
- **Test early**: Use the CLI client to verify your server works
- **Read the logs**: Enable debug mode with `DEBUG=1` for troubleshooting

---

## 🤔 Common Questions

**Q: Which transport should I use?**
A: HTTP Stream is the default and recommended transport for all use cases. HTTP/SSE is available but deprecated.

**Q: How do I test my server?**
A: Use the CLI client: `ruby examples/core_features/cli_client.rb http://localhost:8080/sse`

**Q: Can I add custom tools?**
A: Yes! Follow the patterns in these examples to register your own functions.

**Q: Is input validation required?**
A: Not technically, but highly recommended for security and debugging.

**Q: How do I handle errors?**
A: Use try/catch blocks in your tool handlers and return appropriate error messages.

---

Ready to build something amazing? Start with `minimal_server.rb` and work your way up! 🎉