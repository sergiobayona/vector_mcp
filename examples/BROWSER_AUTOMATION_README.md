# VectorMCP Browser Automation

This directory contains a complete browser automation implementation for VectorMCP, ported from the original Browser MCP project. It enables AI applications like Claude, VS Code, and Cursor to automate web browsers using existing browser profiles and sessions.

## 🎯 Key Advantages

- **🔒 Uses existing browser profiles**: Already logged into Gmail, social media, banking, etc.
- **👤 Real user fingerprint**: Avoids bot detection by using actual browser sessions
- **⚡ Fast local automation**: No network latency or remote browser overhead
- **🔐 Secure**: Leverages VectorMCP's built-in authentication and authorization
- **🌐 Cross-browser compatible**: Works with any Chromium-based browser

## 📁 Files Overview

### Core Implementation
- `browser_server.rb` - Complete browser automation server
- `browser_client_demo.rb` - MCP client demonstration script
- `google_search_demo.rb` - Simplified demo showing automation workflow

### Chrome Extension
- `chrome_extension/manifest.json` - Extension configuration
- `chrome_extension/background.js` - Main extension logic
- `chrome_extension/popup.html` - Extension popup interface
- `chrome_extension/popup.js` - Popup functionality
- `chrome_extension/content.js` - Enhanced DOM interaction

## 🚀 Quick Start

### 1. Start the Browser Automation Server

```bash
# From the VectorMCP root directory
ruby examples/browser_server.rb
```

The server will start on `http://localhost:8000` with these endpoints:
- **MCP Protocol**: `GET /mcp/sse` (for AI clients)
- **Browser Commands**: `POST /browser/*` (for Chrome extension)

### 2. Install Chrome Extension (Optional for Demo)

1. Open Chrome and go to `chrome://extensions/`
2. Enable "Developer mode"
3. Click "Load unpacked" and select the `examples/chrome_extension/` directory
4. The extension will appear in your toolbar

### 3. Run Demo Scripts

```bash
# MCP client demonstration
ruby examples/browser_client_demo.rb

# Simplified workflow demo
ruby examples/google_search_demo.rb
```

## 🔧 Available Browser Tools

The server automatically registers these browser automation tools:

| Tool | Description | Parameters |
|------|-------------|------------|
| `browser_navigate` | Navigate to a URL | `url`, `include_snapshot` |
| `browser_click` | Click elements | `selector`, `coordinate`, `include_snapshot` |
| `browser_type` | Type text | `text`, `selector`, `coordinate` |
| `browser_snapshot` | Get ARIA accessibility tree | None |
| `browser_screenshot` | Take PNG screenshot | None |
| `browser_console` | Get console logs | None |
| `browser_wait` | Pause execution | `duration` (ms) |
| `browser_status` | Check extension status | None |

## 📡 Architecture

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
2. **VectorMCP Server** exposes browser automation tools
3. **Chrome Extension** polls server for commands via HTTP
4. **Extension** executes commands in browser and returns results
5. **Results** flow back to AI client through MCP protocol

## 🎮 Example Usage

### Basic Navigation and Search

```ruby
# This is what an AI client would do
server = VectorMCP::Server.new("BrowserBot")
server.register_browser_tools

# Navigate to Google
result = server.call_tool("browser_navigate", {
  url: "https://www.google.com"
})

# Type search query
server.call_tool("browser_type", {
  text: "vector_mcp gem",
  selector: "input[name='q']"
})

# Submit search
server.call_tool("browser_click", {
  selector: "input[value='Google Search']"
})

# Get results snapshot
snapshot = server.call_tool("browser_snapshot")
```

### Google Search Automation

The demo scripts show a complete Google search workflow:

1. ✅ Check browser extension status
2. ✅ Navigate to Google
3. ✅ Type search query: "vector_mcp gem"
4. ✅ Submit search
5. ✅ Wait for results
6. ✅ Capture page snapshot
7. ✅ Click first organic result
8. ✅ Take screenshot of result page

## 🔐 Security Features

VectorMCP's browser automation inherits all security features:

### Authentication
```ruby
# API Key authentication
server.enable_authentication!(strategy: :api_key, keys: ["secret-key"])

# JWT authentication  
server.enable_authentication!(strategy: :jwt, secret: "jwt-secret")
```

### Authorization
```ruby
server.enable_authorization! do
  authorize_tools do |user, action, tool|
    # Only allow browser tools for admin users
    user[:role] == "admin" || !tool.name.start_with?("browser_")
  end
end
```

## 🐛 Troubleshooting

### Server Won't Start
```bash
# Check if port 8000 is available
lsof -i :8000

# Run with debug output
DEBUG=1 ruby examples/browser_server.rb
```

### Extension Not Connecting
1. Check extension is installed and enabled
2. Verify server is running on `http://localhost:8000`
3. Check browser console for errors
4. Try the "Test Connection" button in extension popup

### Demo Scripts Failing
```bash
# Ensure server is running first
ruby examples/browser_server.rb

# In another terminal, run demo
ruby examples/browser_client_demo.rb
```

## 🔄 Development Workflow

### Adding New Browser Tools

1. **Add tool to VectorMCP server**:
```ruby
server.register_tool(
  name: "browser_scroll",
  description: "Scroll the page",
  input_schema: { /* schema */ }
) do |arguments, session_context|
  # Tool implementation
end
```

2. **Add command handler to Chrome extension**:
```javascript
case 'scroll':
  result = await this.scroll(command.params);
  break;
```

3. **Test with MCP client**:
```ruby
result = client.call_tool("browser_scroll", { direction: "down" })
```

### Extension Development

The Chrome extension uses manifest v3 and includes:
- **Background script**: Polls for commands and coordinates execution
- **Content script**: Enhanced DOM interaction on every page  
- **Popup interface**: Shows connection status and manual controls

## 🚀 Production Deployment

### Server Configuration
```ruby
# Production server with authentication
server = VectorMCP::Server.new("ProductionBrowserBot")
server.enable_authentication!(strategy: :jwt, secret: ENV["JWT_SECRET"])
server.enable_authorization!
server.register_browser_tools

# Run with SSL and custom port
server.run(transport: :sse, host: "0.0.0.0", port: 443)
```

### Extension Distribution
1. Package extension for Chrome Web Store
2. Configure server URL for production environment
3. Implement proper error handling and retry logic

## 📚 Related Documentation

- **VectorMCP Security Guide**: `../security/README.md`
- **MCP Protocol Specification**: https://modelcontextprotocol.io/
- **Original Browser MCP**: https://github.com/browsermcp/mcp

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality  
4. Submit a pull request

## 📄 License

This browser automation implementation follows the same license as VectorMCP.