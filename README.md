# VectorMCP

[![Gem Version](https://badge.fury.io/rb/vector_mcp.svg)](https://badge.fury.io/rb/vector_mcp)
[![Docs](http://img.shields.io/badge/yard-docs-blue.svg)](https://sergiobayona.github.io/vector_mcp/)
[![Build Status](https://github.com/sergiobayona/VectorMCP/actions/workflows/ruby.yml/badge.svg?branch=main)](https://github.com/sergiobayona/vector_mcp/actions/workflows/ruby.yml)
[![Maintainability](https://qlty.sh/badges/fdb143b3-148a-4a86-8e3b-4ccebe993528/maintainability.svg)](https://qlty.sh/gh/sergiobayona/projects/vector_mcp)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

VectorMCP is a Ruby gem implementing the Model Context Protocol (MCP) server-side specification. It provides a framework for creating MCP servers that expose tools, resources, prompts, and roots to LLM clients.

## Why VectorMCP?

- **🛡️ Security-First**: Built-in input validation and schema checking prevent injection attacks
- **⚡ Production-Ready**: Robust error handling, comprehensive test suite, and proven reliability  
- **🔌 Multiple Transports**: stdio for CLI tools, SSE for web applications
- **📦 Zero Configuration**: Works out of the box with sensible defaults
- **🔄 Fully Compatible**: Implements the complete MCP specification

## Quick Start

```bash
gem install vector_mcp
```

```ruby
require 'vector_mcp'

# Create a server
server = VectorMCP.new(name: 'MyApp', version: '1.0.0')

# Add a tool
server.register_tool(
  name: 'greet',
  description: 'Says hello to someone',
  input_schema: {
    type: 'object',
    properties: { name: { type: 'string' } },
    required: ['name']
  }
) { |args| "Hello, #{args['name']}!" }

# Start the server
server.run  # Uses stdio transport by default
```

**That's it!** Your MCP server is ready to connect with Claude Desktop, custom clients, or any MCP-compatible application.

## Transport Options

### Command Line Tools (stdio)

Perfect for desktop applications and process-based integrations:

```ruby
server.run  # Default: stdio transport
```

### Web Applications (HTTP + SSE)

Ideal for web apps and browser-based clients:

```ruby
server.run(transport: :sse, port: 8080)
```

Connect via Server-Sent Events at `http://localhost:8080/sse`

## Core Features

### Tools (Functions)

Expose functions that LLMs can call:

```ruby
server.register_tool(
  name: 'calculate',
  description: 'Performs basic math',
  input_schema: {
    type: 'object',
    properties: {
      operation: { type: 'string', enum: ['add', 'subtract', 'multiply'] },
      a: { type: 'number' },
      b: { type: 'number' }
    },
    required: ['operation', 'a', 'b']
  }
) do |args|
  case args['operation']
  when 'add' then args['a'] + args['b']
  when 'subtract' then args['a'] - args['b']
  when 'multiply' then args['a'] * args['b']
  end
end
```

### Resources (Data Sources)

Provide data that LLMs can read:

```ruby
server.register_resource(
  uri: 'file://config.json',
  name: 'App Configuration',
  description: 'Current application settings'
) { File.read('config.json') }
```

### Prompts (Templates)

Create reusable prompt templates:

```ruby
server.register_prompt(
  name: 'code_review',
  description: 'Reviews code for best practices',
  arguments: [
    { name: 'language', description: 'Programming language', required: true },
    { name: 'code', description: 'Code to review', required: true }
  ]
) do |args|
  {
    messages: [{
      role: 'user',
      content: {
        type: 'text',
        text: "Review this #{args['language']} code:\n\n#{args['code']}"
      }
    }]
  }
end
```

## Built-in Security

VectorMCP automatically validates all inputs against your schemas:

```ruby
# This tool is protected against invalid inputs
server.register_tool(
  name: 'process_user',
  input_schema: {
    type: 'object',
    properties: {
      email: { type: 'string', format: 'email' },
      age: { type: 'integer', minimum: 0, maximum: 150 }
    },
    required: ['email']
  }
) { |args| "Processing #{args['email']}" }

# Invalid inputs are automatically rejected:
# ❌ { email: "not-an-email" }     -> Validation error
# ❌ { age: -5 }                   -> Missing required field
# ✅ { email: "user@example.com" } -> Passes validation
```

## Real-World Examples

### File System Server

```ruby
server.register_tool(
  name: 'read_file',
  description: 'Reads a text file',
  input_schema: {
    type: 'object',
    properties: { path: { type: 'string' } },
    required: ['path']
  }
) { |args| File.read(args['path']) }
```

### Database Query Tool

```ruby
server.register_tool(
  name: 'search_users',
  description: 'Searches users by name',
  input_schema: {
    type: 'object',
    properties: { 
      query: { type: 'string', minLength: 1 },
      limit: { type: 'integer', minimum: 1, maximum: 100 }
    },
    required: ['query']
  }
) do |args|
  User.where('name ILIKE ?', "%#{args['query']}%")
      .limit(args['limit'] || 10)
      .to_json
end
```

### API Integration

```ruby
server.register_tool(
  name: 'get_weather',
  description: 'Gets current weather for a city',
  input_schema: {
    type: 'object',
    properties: { city: { type: 'string' } },
    required: ['city']
  }
) do |args|
  response = HTTP.get("https://api.weather.com/current", params: { city: args['city'] })
  response.parse
end
```

---

## Advanced Usage

<details>
<summary><strong>Filesystem Roots & Security</strong></summary>

Define secure filesystem boundaries:

```ruby
# Register allowed directories
server.register_root_from_path('./src', name: 'Source Code')
server.register_root_from_path('./docs', name: 'Documentation')

# Tools can safely operate within these bounds
server.register_tool(
  name: 'list_files',
  input_schema: {
    type: 'object', 
    properties: { root_uri: { type: 'string' } },
    required: ['root_uri']
  }
) do |args|
  root = server.roots[args['root_uri']]
  raise 'Invalid root' unless root
  Dir.entries(root.path).reject { |f| f.start_with?('.') }
end
```

</details>

<details>
<summary><strong>LLM Sampling (Server → Client)</strong></summary>

Make requests to the connected LLM:

```ruby
server.register_tool(
  name: 'generate_summary',
  input_schema: {
    type: 'object',
    properties: { text: { type: 'string' } },
    required: ['text']
  }
) do |args, session|
  result = session.sample(
    messages: [{ 
      role: 'user', 
      content: { type: 'text', text: "Summarize: #{args['text']}" }
    }],
    max_tokens: 100
  )
  result.text_content
end
```

</details>

<details>
<summary><strong>Custom Error Handling</strong></summary>

Use proper MCP error types:

```ruby
server.register_tool(name: 'risky_operation') do |args|
  if args['dangerous']
    raise VectorMCP::InvalidParamsError.new('Dangerous operation not allowed')
  end
  
  begin
    perform_operation(args)
  rescue SomeError => e
    raise VectorMCP::InternalError.new('Operation failed')
  end
end
```

</details>

<details>
<summary><strong>Session Information</strong></summary>

Access client context:

```ruby
server.register_tool(name: 'client_info') do |args, session|
  {
    client: session.client_info&.dig('name'),
    capabilities: session.client_capabilities,
    initialized: session.initialized?
  }
end
```

</details>

---

## Integration Examples

### Claude Desktop

Add to your Claude Desktop configuration:

```json
{
  "mcpServers": {
    "my-ruby-server": {
      "command": "ruby",
      "args": ["path/to/my_server.rb"]
    }
  }
}
```

### Web Applications

```javascript
// Connect to SSE endpoint
const eventSource = new EventSource('http://localhost:8080/sse');

eventSource.addEventListener('endpoint', (event) => {
  const { uri } = JSON.parse(event.data);
  
  // Send MCP requests
  fetch(uri, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      jsonrpc: '2.0',
      id: 1,
      method: 'tools/call',
      params: { name: 'greet', arguments: { name: 'World' } }
    })
  });
});
```

## Why Choose VectorMCP?

**🏆 Battle-Tested**: Used in production applications serving thousands of requests

**⚡ Performance**: Optimized for low latency and high throughput

**🛡️ Secure by Default**: Comprehensive input validation prevents common attacks  

**📖 Well-Documented**: Extensive examples and clear API documentation

**🔧 Extensible**: Easy to customize and extend for your specific needs

**🤝 Community**: Active development and responsive maintainer

## Examples & Resources

- **[Examples Directory](./examples/)** - Complete working examples
- **[File System MCP](https://github.com/sergiobayona/file_system_mcp)** - Real-world implementation
- **[MCP Specification](https://modelcontext.dev/)** - Official protocol documentation

## Installation & Setup

```bash
gem install vector_mcp

# Or in your Gemfile
gem 'vector_mcp'
```

## Contributing

Bug reports and pull requests welcome on [GitHub](https://github.com/sergiobayona/vector_mcp).

## License

Available as open source under the [MIT License](https://opensource.org/licenses/MIT).