# 🌐 VectorMCP Browser Automation

Complete browser automation system that enables AI applications to control web browsers using existing browser profiles and sessions. This implementation provides secure, fast, and reliable browser automation with VectorMCP's built-in security features.

## 🎯 Key Advantages

- **🔒 Uses existing browser profiles**: Already logged into Gmail, social media, banking, etc.
- **👤 Real user fingerprint**: Avoids bot detection by using actual browser sessions
- **⚡ Fast local automation**: No network latency or remote browser overhead
- **🔐 Enterprise security**: Built-in authentication, authorization, and audit logging
- **🌐 Cross-browser compatible**: Works with any Chromium-based browser

---

## 📚 Examples Overview

### 1. [`basic_browser_server.rb`](./basic_browser_server.rb) ⭐ **START HERE**
**Core browser automation server with essential tools**

```bash
ruby examples/browser_automation/basic_browser_server.rb
# Server runs on http://localhost:8000
```

**What it demonstrates:**
- **Complete browser automation**: Navigate, click, type, screenshot
- **Chrome extension integration**: Real browser control via extension
- **MCP protocol implementation**: Full SSE transport with browser tools
- **Command queue system**: Reliable request/response handling
- **Extension status monitoring**: Connection health and diagnostics

**Available tools:**
- `browser_navigate` - Navigate to URLs
- `browser_click` - Click elements by selector or coordinates  
- `browser_type` - Type text into form fields
- `browser_snapshot` - Get ARIA accessibility tree
- `browser_screenshot` - Capture PNG screenshots
- `browser_console` - Retrieve console logs
- `browser_wait` - Pause execution

**Perfect for:** Getting started with browser automation, development testing

---

### 2. [`secure_browser_server.rb`](./secure_browser_server.rb) 🔐 **PRODUCTION READY**
**Full-featured server with authentication and authorization**

```bash
# API Key authentication
API_KEY=your-secret-key ruby examples/browser_automation/secure_browser_server.rb

# JWT authentication
JWT_SECRET=your-jwt-secret ruby examples/browser_automation/secure_browser_server.rb jwt

# Custom authentication
ruby examples/browser_automation/secure_browser_server.rb custom
```

**What it demonstrates:**
- **Multi-strategy authentication**: API keys, JWT tokens, custom handlers
- **Role-based authorization**: Admin, browser_user, and demo user roles
- **Security logging**: Complete audit trail of browser actions
- **Rate limiting**: Protection against abuse
- **Session management**: Secure user context tracking

**Security features:**
```ruby
# Authentication strategies
server.enable_authentication!(strategy: :api_key, keys: ["secret-key"])
server.enable_authentication!(strategy: :jwt_token, secret: "jwt-secret")

# Authorization policies
server.enable_browser_authorization! do
  admin_full_access
  browser_user_full_access  
  demo_user_limited_access
end
```

**Perfect for:** Production deployments, enterprise environments, multi-tenant systems

---

### 3. [`authorization_demo.rb`](./authorization_demo.rb) 🛡️ **SECURITY PATTERNS**
**Role-based access control for browser automation**

```bash
ruby examples/browser_automation/authorization_demo.rb
```

**What it demonstrates:**
- **Role definitions**: Admin, browser_user, demo user hierarchies
- **Tool-level permissions**: Fine-grained access control
- **Domain restrictions**: Limiting navigation to approved sites
- **Permission inheritance**: Role-based capability delegation
- **Policy configuration**: Flexible authorization rule setup

**Authorization patterns:**
```ruby
# Admin users - full access
server.enable_browser_authorization! do
  admin_full_access
end

# Browser users - all browser tools
server.enable_browser_authorization! do
  browser_user_full_access
end

# Demo users - limited access
server.enable_browser_authorization! do
  demo_user_limited_access  # Only navigate and snapshot
end

# Custom policies
server.enable_browser_authorization! do
  restrict_to_domains("example.com", "trusted.org") do |user|
    user[:role] == "restricted_user"
  end
end
```

**Perfect for:** Understanding security patterns, implementing custom policies

---

### 4. [`browser_client_demo.rb`](./browser_client_demo.rb) 🖥️ **CLIENT EXAMPLE**
**MCP client demonstrating browser automation workflow**

```bash
# Make sure server is running first
ruby examples/browser_automation/basic_browser_server.rb

# In another terminal
ruby examples/browser_automation/browser_client_demo.rb
```

**What it demonstrates:**
- **MCP client implementation**: Connecting to browser automation servers
- **Tool invocation patterns**: Calling browser tools with proper parameters
- **Error handling**: Dealing with connection issues and command failures
- **Workflow orchestration**: Chaining browser actions together
- **Result processing**: Handling screenshots, snapshots, and data

**Perfect for:** Building custom automation scripts, understanding client patterns

---

### 5. [`google_search_demo.rb`](./google_search_demo.rb) 🔍 **WORKFLOW EXAMPLE**
**Complete Google search automation demonstration**

```bash
# Ensure server and extension are running
ruby examples/browser_automation/google_search_demo.rb
```

**What it demonstrates:**
- **End-to-end workflow**: Complete automation from start to finish
- **Real website interaction**: Working with actual Google search
- **Error recovery**: Handling timeouts and unexpected states
- **Data extraction**: Capturing results and taking screenshots
- **Best practices**: Proper timing, element selection, and validation

**Workflow steps:**
1. ✅ Check extension connection status
2. ✅ Navigate to Google homepage
3. ✅ Enter search query: "vector_mcp gem"
4. ✅ Submit search form
5. ✅ Wait for results to load
6. ✅ Capture page snapshot
7. ✅ Click first result
8. ✅ Take screenshot of result page

**Perfect for:** Learning automation patterns, demonstrating capabilities

---

## 🏗️ Architecture

```
AI Client (Claude/VS Code/Cursor)
    ↓ JSON-RPC over SSE
VectorMCP Server (Ruby)
    ↓ HTTP REST API  
Chrome Extension
    ↓ Chrome APIs
Browser Tab (Your logged-in session)
```

### Communication Flow

1. **AI Client** connects to VectorMCP server via SSE transport
2. **VectorMCP Server** exposes browser automation tools via MCP protocol
3. **Chrome Extension** polls server for commands via HTTP endpoints
4. **Extension** executes commands in browser using Chrome APIs
5. **Results** flow back to AI client through MCP protocol

---

## 🚀 Quick Start

### 1. Install Chrome Extension

1. Open Chrome and navigate to `chrome://extensions/`
2. Enable "Developer mode" in the top right
3. Click "Load unpacked" and select `examples/browser_automation/chrome_extension/`
4. The extension will appear in your toolbar

### 2. Start Browser Server

```bash
# Basic server (no authentication)
ruby examples/browser_automation/basic_browser_server.rb

# Secure server (with authentication)
API_KEY=your-secret-key ruby examples/browser_automation/secure_browser_server.rb
```

### 3. Test the Connection

```bash
# Check extension status
curl http://localhost:8000/browser/ping

# In another terminal, run demo
ruby examples/browser_automation/browser_client_demo.rb
```

---

## 🔧 Available Browser Tools

| Tool | Description | Parameters | Security Level |
|------|-------------|------------|----------------|
| `browser_navigate` | Navigate to URL | `url`, `include_snapshot` | Basic |
| `browser_click` | Click elements | `selector`, `coordinate` | Moderate |
| `browser_type` | Type text | `text`, `selector`, `coordinate` | Moderate |
| `browser_snapshot` | Get ARIA tree | None | Basic |
| `browser_screenshot` | Take screenshot | None | Basic |
| `browser_console` | Get console logs | None | Basic |
| `browser_wait` | Pause execution | `duration` (ms) | Basic |

### Security Levels
- **Basic**: Safe read-only operations
- **Moderate**: Actions that modify page state
- **High**: Administrative or system-level operations

---

## 🔐 Security Features

### Authentication Options

**API Key Authentication:**
```bash
API_KEY=your-secret-key ruby examples/browser_automation/secure_browser_server.rb
```

**JWT Token Authentication:**
```bash
JWT_SECRET=your-jwt-secret ruby examples/browser_automation/secure_browser_server.rb jwt
```

**Custom Authentication:**
```ruby
server.enable_authentication!(strategy: :custom) do |request|
  api_key = request[:headers]["X-API-Key"]
  authenticate_with_database(api_key)
end
```

### Authorization Policies

**Role-based Access:**
```ruby
server.enable_browser_authorization! do
  # Admins can do everything
  admin_full_access
  
  # Browser users can use all browser tools
  browser_user_full_access
  
  # Demo users limited to safe operations
  demo_user_limited_access
end
```

**Domain Restrictions:**
```ruby
server.enable_browser_authorization! do
  restrict_to_domains("company.com", "trusted-partner.org") do |user|
    user[:role] != "admin"  # Admins can navigate anywhere
  end
end
```

---

## 🛠️ Development Workflow

### Adding New Browser Tools

1. **Register tool in VectorMCP server:**
```ruby
server.register_tool(
  name: "browser_scroll",
  description: "Scroll the page",
  input_schema: {
    type: "object", 
    properties: {
      direction: { type: "string", enum: %w[up down] },
      amount: { type: "integer", minimum: 1, maximum: 10 }
    }
  }
) do |arguments, session_context|
  # Tool implementation calls browser server
  scroll_page(arguments["direction"], arguments["amount"])
end
```

2. **Add command handler to Chrome extension:**
```javascript
// In chrome_extension/background.js
case 'scroll':
  const direction = command.params.direction;
  const amount = command.params.amount || 3;
  result = await this.scrollPage(direction, amount);
  break;
```

3. **Test with MCP client:**
```ruby
result = client.call_tool("browser_scroll", { 
  "direction" => "down", 
  "amount" => 3 
})
```

### Extension Development

The Chrome extension (`chrome_extension/`) includes:

- **`manifest.json`**: Extension configuration (permissions, version, etc.)
- **`background.js`**: Main extension logic (polls for commands, executes actions)
- **`content.js`**: Enhanced DOM interaction injected into every page
- **`popup.html/js`**: Extension popup interface for manual testing

---

## 🐛 Troubleshooting

### Server Won't Start
```bash
# Check if port 8000 is available
lsof -i :8000

# Kill process using port
kill -9 $(lsof -t -i:8000)

# Run with debug output
DEBUG=1 ruby examples/browser_automation/basic_browser_server.rb
```

### Extension Not Connecting
1. **Verify extension is installed and enabled**
2. **Check server is running on correct port**
3. **Open browser console for errors**
4. **Test connection manually:**
```bash
curl -X POST http://localhost:8000/browser/ping
```

### Commands Timing Out
1. **Check Chrome extension is active**
2. **Verify extension permissions are granted**
3. **Increase timeout in client code**
4. **Check for JavaScript errors in browser console**

### Authentication Issues
```bash
# Test API key authentication
curl -H "X-API-Key: your-key" http://localhost:8000/mcp/sse

# Check server logs for authentication failures
grep "authentication" /var/log/vectormcp.log
```

---

## 📊 Monitoring & Observability

### Health Checks
```bash
# Extension status
curl http://localhost:8000/browser/ping

# Server health
curl http://localhost:8000/

# Command queue status
curl http://localhost:8000/browser/stats
```

### Logging Configuration
```ruby
# Enable detailed browser automation logging
VectorMCP.configure_logging do
  component "browser.queue", level: "DEBUG"
  component "browser.tools", level: "INFO"
  component "security.browser", level: "INFO"
end
```

### Performance Metrics
```ruby
# Built-in performance measurement
browser_logger = VectorMCP.logger_for("browser.operations")

result = browser_logger.measure("Page navigation") do
  navigate_to_url(url)
end

# Logs: "Page navigation completed in 1.2s"
```

---

## 🚀 Production Deployment

### Server Configuration
```ruby
# Production server setup
server = VectorMCP::Server.new("ProductionBrowserBot")

# Enable security
server.enable_authentication!(strategy: :jwt_token, secret: ENV["JWT_SECRET"])
server.enable_authorization!
server.register_browser_tools

# Configure logging
VectorMCP.configure_logging do
  level "INFO"
  format "json"
  output "file" 
  file_path "/var/log/vectormcp/browser.log"
end

# Run with production settings
server.run(transport: :sse, host: "0.0.0.0", port: 8000)
```

### Extension Distribution
1. **Package extension for Chrome Web Store**
2. **Configure production server URL**
3. **Implement retry logic and error handling**
4. **Add user onboarding and documentation**

---

## 📚 Related Documentation

- **[VectorMCP Security Guide](../../security/README.md)**: Authentication and authorization
- **[Core Features](../core_features/README.md)**: Input validation and security patterns
- **[Logging Guide](../logging/README.md)**: Monitoring and observability
- **[MCP Specification](https://modelcontext.dev/)**: Protocol details

---

Ready to automate the web with VectorMCP? Start with `basic_browser_server.rb` and level up to production-ready automation! 🌐🚀