# Migrating from SSE to HTTP Stream Transport

**Document Version**: 1.0
**Last Updated**: 2025-10-23
**Applies To**: VectorMCP v0.4.0 through v0.9.x

---

## 📋 Overview

This guide helps you migrate from the deprecated SSE (Server-Sent Events) transport to the recommended HTTP Stream transport in VectorMCP.

### Why Migrate?

- **MCP Specification**: SSE transport was deprecated in MCP specification 2024-11-05
- **Better Compatibility**: HTTP Stream provides better alignment with current MCP standards
- **Future Support**: SSE will be removed in VectorMCP v1.0.0

### Timeline

| Version | Status | Action |
|---------|--------|--------|
| v0.4.0 - v0.9.x | Deprecated with warnings | Migrate at your convenience |
| v1.0.0+ | Removed | Migration required to use new versions |

---

## 🚀 Quick Migration

### For Server Code

The simplest migration requires just one line change:

```ruby
# ❌ Before (SSE)
server.run(transport: :sse, port: 8080, host: "localhost")

# ✅ After (HTTP Stream)
server.run(transport: :http_stream, port: 8080, host: "localhost")
```

That's it for basic usage! The HTTP Stream transport maintains the same API.

### For Client Code

Client applications need to update their endpoint URLs and session handling:

```ruby
# ❌ Before (SSE)
# Connect to SSE stream
sse_connection = connect_to("http://localhost:8080/mcp/sse")
# Post messages with session_id as query parameter
post_message("http://localhost:8080/mcp/message?session_id=#{session_id}", message)

# ✅ After (HTTP Stream)
# Post messages with session_id as header
post_message("http://localhost:8080/mcp", message,
  headers: { "Mcp-Session-Id" => session_id })
# Optionally connect to streaming endpoint
stream_connection = connect_to("http://localhost:8080/mcp")
```

---

## 📊 Detailed Differences

### Endpoint Structure

| Aspect | SSE Transport | HTTP Stream Transport |
|--------|---------------|----------------------|
| **Base Path** | `/mcp` (configurable) | `/mcp` (configurable) |
| **SSE Connection** | `GET /mcp/sse` | `GET /mcp` (optional streaming) |
| **Message Posting** | `POST /mcp/message?session_id=X` | `POST /mcp` |
| **Session ID** | Query parameter | Header `Mcp-Session-Id` |

### Session Management

**SSE Approach**:
1. Client connects to `GET /mcp/sse`
2. Server sends `event: endpoint` with session info
3. Client receives session_id from SSE message
4. Client posts to `/mcp/message?session_id=X`

**HTTP Stream Approach**:
1. Client sends `POST /mcp` with `Mcp-Session-Id` header
2. Server creates or reuses session based on header
3. Optional: Client connects to `GET /mcp` for server-initiated messages
4. Session management via explicit DELETE `/mcp` endpoint

### Configuration Options

Most configuration options remain the same:

```ruby
# Both transports support:
{
  host: "localhost",      # Binding host
  port: 8080,            # Listening port
  path_prefix: "/mcp"    # Base URL path (optional)
}
```

**SSE-only options that are removed**:
- `disable_session_manager` - Not needed in HTTP Stream (always uses session manager)

---

## 🔧 Step-by-Step Migration

### Step 1: Update Server Code

**Before** - SSE Server:
```ruby
require "vectormcp"

server = VectorMCP.new(
  name: "MyServer",
  version: "1.0.0"
)

# Register tools, resources, prompts...
server.register_tool(
  name: "echo",
  description: "Echo back input",
  input_schema: { type: "object", properties: { text: { type: "string" } } }
) do |params|
  params[:text]
end

# Start with SSE transport
server.run(
  transport: :sse,
  port: 8080,
  host: "localhost",
  path_prefix: "/mcp"
)
```

**After** - HTTP Stream Server:
```ruby
require "vectormcp"

server = VectorMCP.new(
  name: "MyServer",
  version: "1.0.0"
)

# Register tools, resources, prompts...
# (No changes needed to registration code)
server.register_tool(
  name: "echo",
  description: "Echo back input",
  input_schema: { type: "object", properties: { text: { type: "string" } } }
) do |params|
  params[:text]
end

# Start with HTTP Stream transport
server.run(
  transport: :http_stream,  # ← Only change needed!
  port: 8080,
  host: "localhost",
  path_prefix: "/mcp"       # Optional, same as before
)
```

**Key Point**: Tool, resource, and prompt registrations require **no changes**.

---

### Step 2: Update Client Connection Code

#### A. Session Initialization

**Before** - SSE Client:
```ruby
require "net/http"
require "json"

# Connect to SSE endpoint
sse_uri = URI("http://localhost:8080/mcp/sse")
http = Net::HTTP.new(sse_uri.host, sse_uri.port)

# Open persistent connection for SSE
request = Net::HTTP::Get.new(sse_uri.path)
http.request(request) do |response|
  response.read_body do |chunk|
    # Parse SSE events
    if chunk =~ /event: endpoint/
      # Extract session_id and message URL from SSE data
      data_line = chunk.split("\n").find { |l| l.start_with?("data:") }
      data = JSON.parse(data_line.sub("data: ", ""))
      @session_id = data["sessionId"]
      @message_url = data["url"]  # e.g., "/mcp/message?session_id=..."
    end
  end
end
```

**After** - HTTP Stream Client:
```ruby
require "net/http"
require "json"
require "securerandom"

# Generate or reuse session ID
@session_id = SecureRandom.uuid

# Initialize session with first request
initialize_uri = URI("http://localhost:8080/mcp")
initialize_request = Net::HTTP::Post.new(initialize_uri.path)
initialize_request["Content-Type"] = "application/json"
initialize_request["Mcp-Session-Id"] = @session_id

initialize_payload = {
  jsonrpc: "2.0",
  id: 1,
  method: "initialize",
  params: {
    protocolVersion: "2024-11-05",
    capabilities: {},
    clientInfo: { name: "MyClient", version: "1.0.0" }
  }
}
initialize_request.body = initialize_payload.to_json

http = Net::HTTP.new(initialize_uri.host, initialize_uri.port)
response = http.request(initialize_request)

# Session is now initialized
puts "Session initialized: #{@session_id}"
```

#### B. Sending Messages

**Before** - SSE Message Posting:
```ruby
# Post to message endpoint with session_id as query parameter
message_uri = URI(@message_url)  # Includes ?session_id=...
request = Net::HTTP::Post.new(message_uri.path + "?" + message_uri.query)
request["Content-Type"] = "application/json"
request.body = {
  jsonrpc: "2.0",
  id: 2,
  method: "tools/list",
  params: {}
}.to_json

response = http.request(request)
```

**After** - HTTP Stream Message Posting:
```ruby
# Post to /mcp with session_id as header
message_uri = URI("http://localhost:8080/mcp")
request = Net::HTTP::Post.new(message_uri.path)
request["Content-Type"] = "application/json"
request["Mcp-Session-Id"] = @session_id  # ← Header instead of query param

request.body = {
  jsonrpc: "2.0",
  id: 2,
  method: "tools/list",
  params: {}
}.to_json

response = http.request(request)
result = JSON.parse(response.body)
```

#### C. Receiving Server-Initiated Messages (Optional)

**Before** - SSE Stream:
```ruby
# SSE automatically receives server messages via open SSE connection
sse_uri = URI("http://localhost:8080/mcp/sse")
# Connection stays open, receives events automatically
```

**After** - HTTP Stream (Optional Streaming):
```ruby
# Optional: Connect to streaming endpoint for server-initiated messages
stream_uri = URI("http://localhost:8080/mcp")
stream_request = Net::HTTP::Get.new(stream_uri.path)
stream_request["Mcp-Session-Id"] = @session_id
stream_request["Last-Event-ID"] = last_event_id if last_event_id  # For resumability

http.request(stream_request) do |response|
  response.read_body do |chunk|
    # Process server-sent events
    puts "Received: #{chunk}"
  end
end
```

**Note**: HTTP Stream streaming is **optional**. Many clients work fine with just POST requests.

---

### Step 3: Update Tests

**Before** - SSE Test:
```ruby
RSpec.describe "SSE Integration" do
  let(:server) { VectorMCP::Server.new(name: "test") }

  it "handles requests via SSE" do
    transport = VectorMCP::Transport::SSE.new(server, port: 9999)
    # Test SSE-specific behavior
  end
end
```

**After** - HTTP Stream Test:
```ruby
RSpec.describe "HTTP Stream Integration" do
  let(:server) { VectorMCP::Server.new(name: "test") }

  it "handles requests via HTTP Stream" do
    transport = VectorMCP::Transport::HttpStream.new(server, port: 9999)
    # Test HTTP Stream behavior
  end
end
```

---

### Step 4: Update Environment Variables (If Used)

If you're using environment variables to configure transport:

```bash
# Before
TRANSPORT=sse
PORT=8080

# After
TRANSPORT=http_stream
PORT=8080
```

```ruby
# In your code:
transport_type = ENV.fetch("TRANSPORT", "stdio").to_sym
server.run(transport: transport_type, port: ENV.fetch("PORT", 8080).to_i)
```

---

### Step 5: Update Deployment Configuration

#### Docker

**Before** - Dockerfile with SSE:
```dockerfile
# No changes needed! Falcon is still used by HTTP Stream
EXPOSE 8080
CMD ["ruby", "server.rb"]  # Uses SSE
```

**After** - Dockerfile with HTTP Stream:
```dockerfile
# Same configuration
EXPOSE 8080
CMD ["ruby", "server.rb"]  # Uses HTTP Stream
```

#### Nginx/Reverse Proxy

**Before** - SSE Configuration:
```nginx
location /mcp/sse {
    proxy_pass http://backend:8080;
    proxy_set_header Connection '';
    proxy_http_version 1.1;
    chunked_transfer_encoding off;
    proxy_buffering off;
    proxy_cache off;
}

location /mcp/message {
    proxy_pass http://backend:8080;
}
```

**After** - HTTP Stream Configuration:
```nginx
location /mcp {
    proxy_pass http://backend:8080;

    # For streaming support (optional):
    proxy_set_header Connection '';
    proxy_http_version 1.1;
    chunked_transfer_encoding off;
    proxy_buffering off;
    proxy_cache off;

    # Pass through session header
    proxy_set_header Mcp-Session-Id $http_mcp_session_id;
}
```

**Simplification**: HTTP Stream uses a single endpoint instead of two!

---

## 🐛 Troubleshooting

### Issue: "SSE transport is deprecated" Warning

**Symptom**: Seeing deprecation warnings when starting server

```
DEPRECATION WARNING: SSE transport is deprecated and will be removed in v1.0.0
```

**Solution**: Update your code to use `:http_stream` as shown in this guide.

---

### Issue: "Invalid session_id" Error

**Symptom**: Client receives 404 or "Invalid session_id" error

**Cause**: SSE used query parameters, HTTP Stream uses headers

**Solution**:
```ruby
# ❌ Wrong - Query parameter
POST /mcp?session_id=abc123

# ✅ Correct - Header
POST /mcp
Mcp-Session-Id: abc123
```

---

### Issue: Not Receiving Server Messages

**Symptom**: Server-initiated notifications don't reach client

**Cause**: HTTP Stream streaming is optional and requires explicit connection

**Solution**:
```ruby
# Option 1: Use polling (simple)
loop do
  response = post_request("/mcp", { method: "notifications/check" })
  sleep 1
end

# Option 2: Connect to streaming endpoint (advanced)
http.request(stream_request) do |response|
  response.read_body { |chunk| handle_message(chunk) }
end
```

---

### Issue: Port Already in Use

**Symptom**: Cannot start server, port conflict error

**Cause**: Old SSE server still running

**Solution**:
```bash
# Kill old process
lsof -ti:8080 | xargs kill -9

# Or use different port
server.run(transport: :http_stream, port: 8081)
```

---

### Issue: Falcon Dependency Missing

**Symptom**: `LoadError: cannot load such file -- falcon/server`

**Cause**: Falcon is required by both SSE and HTTP Stream

**Solution**:
```bash
# Ensure Falcon is installed
bundle install

# Or install directly
gem install falcon
```

**Note**: Falcon will NOT be removed when SSE is removed, as HTTP Stream also uses it.

---

## ✅ Migration Checklist

Use this checklist to ensure complete migration:

### Server-Side

- [ ] Update `server.run()` to use `transport: :http_stream`
- [ ] Remove SSE-specific configuration options (if any)
- [ ] Update server tests to use HTTP Stream
- [ ] Update deployment scripts/configs
- [ ] Update documentation/README

### Client-Side

- [ ] Update endpoint URLs (`/mcp/sse` + `/mcp/message` → `/mcp`)
- [ ] Change session ID from query parameter to header
- [ ] Update session initialization logic
- [ ] Update message sending code
- [ ] Update streaming connection (if used)
- [ ] Update client tests
- [ ] Update client documentation

### Testing

- [ ] Run full test suite
- [ ] Test session creation and management
- [ ] Test tool invocation
- [ ] Test resource reading
- [ ] Test prompt execution
- [ ] Test authentication (if enabled)
- [ ] Test server-initiated messages (if used)
- [ ] Load test (if SSE had specific performance characteristics)

### Deployment

- [ ] Update staging environment
- [ ] Test in staging
- [ ] Update production configuration
- [ ] Deploy to production
- [ ] Monitor for issues
- [ ] Update monitoring/alerting (if endpoint-specific)

---

## 📚 Additional Resources

### Official Documentation

- [VectorMCP HTTP Stream Transport](../CLAUDE.md#http-stream-transport)
- [MCP Specification 2024-11-05](https://spec.modelcontextprotocol.io/)
- [VectorMCP Examples](../examples/getting_started/)

### Example Code

Complete working examples available:
- [Basic HTTP Stream Server](../examples/getting_started/basic_http_stream_server.rb)
- [Minimal Server](../examples/getting_started/minimal_server.rb)

### Getting Help

- **GitHub Issues**: [Report migration problems](https://github.com/yourusername/vectormcp/issues)
- **Discussions**: [Ask questions](https://github.com/yourusername/vectormcp/discussions)
- **Documentation**: [Full API docs](https://vectormcp.dev/docs)

---

## 🎯 Key Takeaways

1. **Simple Server Migration**: Change one line - `transport: :sse` to `transport: :http_stream`

2. **Client Updates Required**: Session ID moves from query parameter to header

3. **Endpoint Consolidation**: Two endpoints (`/sse`, `/message`) become one (`/mcp`)

4. **Minimal Breaking Changes**: Core functionality remains the same

5. **Timeline**: Migrate before v1.0.0 (Q4 2025) to avoid breakage

---

## ❓ FAQ

### Q: When will SSE be removed?

**A**: SSE will be completely removed in VectorMCP v1.0.0, expected Q4 2025.

---

### Q: Can I use both SSE and HTTP Stream during migration?

**A**: Yes! You can run separate server instances with different transports during migration:

```ruby
# SSE server for legacy clients
sse_server = VectorMCP.new(name: "LegacyServer")
sse_server.run(transport: :sse, port: 8080)

# HTTP Stream server for new clients
http_server = VectorMCP.new(name: "NewServer")
http_server.run(transport: :http_stream, port: 8081)
```

---

### Q: Will my tools/resources/prompts work without changes?

**A**: Yes! All tool, resource, and prompt registrations work identically. Only transport layer changes.

---

### Q: Is HTTP Stream as performant as SSE?

**A**: Yes. Both use Falcon with async I/O. Performance characteristics are equivalent.

---

### Q: Do I need to update my authentication setup?

**A**: No. Authentication and authorization work the same with HTTP Stream.

---

### Q: What if I encounter issues during migration?

**A**:
1. Check this troubleshooting section
2. Review the examples in `examples/getting_started/`
3. Open a GitHub issue with details
4. SSE remains functional during deprecation period (v0.4.0 - v0.9.x)

---

### Q: Can I still use SSE after v1.0.0?

**A**: No. SSE transport will be completely removed. Attempting to use `:sse` will raise an error:

```ruby
ArgumentError: SSE transport was removed in VectorMCP v1.0.0.
Please use :http_stream transport instead.
```

---

## 📝 Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-10-23 | Initial migration guide |

---

**Last Updated**: 2025-10-23
**Maintained Until**: VectorMCP v2.0.0 (for historical reference)
