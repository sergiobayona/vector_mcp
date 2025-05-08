# VectorMCP

<!-- Badges (Add URLs later) -->
[![Gem Version](https://badge.fury.io/rb/vector_mcp.svg)](https://badge.fury.io/rb/vector_mcp)
[![Docs](http://img.shields.io/badge/yard-docs-blue.svg)](https://sergiobayona.github.io/vector_mcp/)
[![Build Status](https://github.com/sergiobayona/VectorMCP/actions/workflows/ruby.yml/badge.svg?branch=main)](https://github.com/sergiobayona/vector_mcp/actions/workflows/ruby.yml)
[![Maintainability](https://qlty.sh/badges/fdb143b3-148a-4a86-8e3b-4ccebe993528/maintainability.svg)](https://qlty.sh/gh/sergiobayona/projects/vector_mcp)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

VectorMCP provides server-side tools for implementing the [Model Context Protocol (MCP)](https://modelcontext.dev/) in Ruby applications. MCP is a specification for how Large Language Models (LLMs) can discover and interact with external tools, resources, and prompts provided by separate applications (MCP Servers).

This library allows you to easily create MCP servers that expose your application's capabilities (like functions, data sources, or predefined prompt templates) to compatible LLM clients (e.g., Claude Desktop App, custom clients).

## Features

*   **MCP Specification Adherence:** Implements core server-side aspects of the MCP specification.
*   **Tools:** Define and register custom tools (functions) that the LLM can invoke.
*   **Resources:** Expose data sources (files, database results, API outputs) for the LLM to read.
*   **Prompts:** Provide structured prompt templates the LLM can request and use.
*   **Transport:**
    *   **Stdio (stable):** Simple transport using standard input/output, ideal for process-based servers.
    *   **SSE (work-in-progress):** Server-Sent Events support is under active development and currently unavailable.

## Installation

```ruby
# In your Gemfile
gem 'vector_mcp'

# Or install directly
gem install vector_mcp
```

> ⚠️  **Note:** SSE transport is not yet supported in the released gem.

## Quick Start

```ruby
require 'vector_mcp'

# Create a server
server = VectorMCP.new('Echo Server')

# Register a tool
server.register_tool(
  name: 'echo',
  description: 'Returns whatever message you send.',
  input_schema: {
    type: 'object',
    properties: { message: { type: 'string' } },
    required: ['message']
  }
) { |args, _session| args['message'] }

# Start listening on STDIN/STDOUT
server.run
```

**To test with stdin/stdout:**

```bash
$ ruby my_server.rb
# Then paste JSON-RPC requests, one per line:
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"CLI","version":"0.1"}}}
```

Or use a script:

```bash
{ 
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"CLI","version":"0.1"}}}';
  printf '%s\n' '{"jsonrpc":"2.0","method":"initialized"}';
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}';
  printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"message":"Hello VectorMCP!"}}}';
} | ruby my_server.rb | jq
```

## Core Usage

### Creating a Server

```ruby
server = VectorMCP.new(
  name: "MyServer",
  version: "1.0.0",
  log_level: Logger::INFO
)
```

### Registering Tools

Tools are functions your server exposes to clients.

```ruby
server.register_tool(
  name: "calculate_sum",
  description: "Adds two numbers together.",
  input_schema: {
    type: "object",
    properties: {
      a: { type: "number" },
      b: { type: "number" }
    },
    required: ["a", "b"]
  }
) do |args, session|
  sum = args["a"] + args["b"]
  "The sum is: #{sum}"
end
```

- `input_schema`: A JSON Schema object describing the tool's expected arguments
- Return value is automatically converted to MCP content format:
  - String → `{type: 'text', text: '...'}`
  - Hash with proper MCP structure → used as-is
  - Other Hash → JSON-encoded text
  - Binary data → Base64-encoded blob

### Registering Resources

Resources are data sources clients can read.

```ruby
server.register_resource(
  uri: "memory://status",
  name: "Server Status",
  description: "Current server status.",
  mime_type: "application/json"
) do |session|
  {
    status: "OK",
    uptime: Time.now - server_start_time
  }
end
```

- `uri`: Unique identifier for the resource
- `mime_type`: Helps clients interpret the data (optional, defaults to "text/plain")
- Return types similar to tools: strings, hashes, binary data

### Registering Prompts

Prompts are templates or workflows clients can request.

```ruby
server.register_prompt(
  name: "project_summary_generator",
  description: "Creates a project summary.",
  arguments: [
    { name: "project_name", description: "Project name", type: "string", required: true },
    { name: "project_goal", description: "Project objective", type: "string", required: true }
  ]
) do |args, session|
  {
    description: "Project summary prompt for '#{args["project_name"]}'",
    messages: [
      {
        role: "user",
        content: {
          type: "text",
          text: "Generate a summary for project '#{args["project_name"]}'. " \
                "The main goal is '#{args["project_goal"]}'."
        }
      }
    ]
  }
end
```

- `arguments`: Defines the parameters this prompt template expects
- Return a Hash conforming to the MCP `GetPromptResult` schema with a `messages` array

## Advanced Features

### Session Object

The `session` object provides client context and connection state.

```ruby
# Access client information
client_name = session.client_info&.dig('name')
client_capabilities = session.client_capabilities

# Check if the client is fully initialized
if session.initialized?
  # Perform operations
end
```

### Custom Handlers

Override default behaviors or add custom methods.

```ruby
# Custom request handler
server.on_request("my_server/status") do |params, session, server|
  { status: "OK", server_name: server.name }
end

# Custom notification handler
server.on_notification("my_server/log") do |params, session, server|
  server.logger.info("Event: #{params['message']}")
end
```

### Error Handling

Use proper error classes for correct JSON-RPC error responses.

```ruby
# In a tool handler
if resource_not_found
  raise VectorMCP::NotFoundError.new("Resource not available")
elsif invalid_parameters
  raise VectorMCP::InvalidParamsError.new("Invalid parameter format")
end
```

Common error classes:
- `VectorMCP::InvalidRequestError`
- `VectorMCP::MethodNotFoundError`
- `VectorMCP::InvalidParamsError`
- `VectorMCP::NotFoundError`
- `VectorMCP::InternalError`

## Example Implementations

These projects demonstrate real-world implementations of VectorMCP servers:

### [file_system_mcp](https://github.com/sergiobayona/file_system_mcp)

A complete MCP server providing filesystem operations:
- Read/write files
- Create/list/delete directories
- Move files/directories
- Search files
- Get file metadata

Works with Claude Desktop and other MCP clients.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/sergiobayona/vector_mcp.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
