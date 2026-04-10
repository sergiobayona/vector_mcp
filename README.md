# VectorMCP

[![Gem Version](https://badge.fury.io/rb/vector_mcp.svg)](https://badge.fury.io/rb/vector_mcp)
[![Docs](http://img.shields.io/badge/yard-docs-blue.svg)](https://sergiobayona.github.io/vector_mcp/)
[![Build Status](https://github.com/sergiobayona/VectorMCP/actions/workflows/ruby.yml/badge.svg?branch=main)](https://github.com/sergiobayona/vector_mcp/actions/workflows/ruby.yml)
[![Maintainability](https://qlty.sh/badges/fdb143b3-148a-4a86-8e3b-4ccebe993528/maintainability.svg)](https://qlty.sh/gh/sergiobayona/projects/vector_mcp)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

VectorMCP is a Ruby implementation of the Model Context Protocol (MCP) server-side specification. It gives you a framework for exposing tools, resources, prompts, roots, sampling, middleware, and security over the MCP streamable HTTP transport.

## Highlights

- Streamable HTTP is the built-in transport, with session management, resumability, and MCP 2025-11-25 compliance
- Class-based tools via `VectorMCP::Tool`, plus the original block-based `register_tool` API
- Rack and Rails mounting through `server.rack_app`
- Opt-in authentication and authorization, structured logging, and middleware hooks
- Image-aware tools/resources/prompts, roots, and server-initiated sampling

## Requirements

- Ruby 3.2+

## Installation

```bash
gem install vector_mcp
```

```ruby
gem "vector_mcp"
```

## Quick Start

```ruby
require "vector_mcp"

class Greet < VectorMCP::Tool
  description "Say hello to someone"
  param :name, type: :string, desc: "Name to greet", required: true

  def call(args, _session)
    "Hello, #{args["name"]}!"
  end
end

server = VectorMCP::Server.new(name: "MyApp", version: "1.0.0")
server.register(Greet)
server.run(port: 8080)
```

The class-based DSL is optional. The existing block-based API still works:

```ruby
server.register_tool(
  name: "echo",
  description: "Echo back the supplied text",
  input_schema: {
    type: "object",
    properties: { text: { type: "string" } },
    required: ["text"]
  }
) { |args| args["text"] }
```

## Rack and Rails

VectorMCP can run as a standalone HTTP server or be mounted inside an existing Rack app:

```ruby
require "vector_mcp"

server = VectorMCP::Server.new(name: "MyApp", version: "1.0.0")
server.register(Greet)

MCP_APP = server.rack_app
```

In Rails, mount it in `config/routes.rb`:

```ruby
mount MCP_APP => "/mcp"
```

For ActiveRecord-backed tools, opt into `VectorMCP::Rails::Tool`:

```ruby
require "vector_mcp/rails/tool"

class FindUser < VectorMCP::Rails::Tool
  description "Find a user by id"
  param :id, type: :integer, required: true

  def call(args, _session)
    user = find!(User, args[:id])
    { id: user.id, email: user.email }
  end
end
```

See [docs/rails-setup-guide.md](./docs/rails-setup-guide.md) for a full setup guide.

## Tools, Resources, and Prompts

Expose callable tools:

```ruby
server.register_tool(
  name: "calculate",
  description: "Performs basic math",
  input_schema: {
    type: "object",
    properties: {
      operation: { type: "string", enum: ["add", "subtract", "multiply"] },
      a: { type: "number" },
      b: { type: "number" }
    },
    required: ["operation", "a", "b"]
  }
) do |args|
  case args["operation"]
  when "add" then args["a"] + args["b"]
  when "subtract" then args["a"] - args["b"]
  when "multiply" then args["a"] * args["b"]
  end
end
```

Expose readable resources:

```ruby
server.register_resource(
  uri: "file://config.json",
  name: "App Configuration",
  description: "Current application settings"
) { File.read("config.json") }
```

Define prompt templates:

```ruby
server.register_prompt(
  name: "code_review",
  description: "Reviews code for best practices",
  arguments: [
    { name: "language", description: "Programming language", required: true },
    { name: "code", description: "Code to review", required: true }
  ]
) do |args|
  {
    messages: [{
      role: "user",
      content: {
        type: "text",
        text: "Review this #{args["language"]} code:\n\n#{args["code"]}"
      }
    }]
  }
end
```

`VectorMCP::Tool` also supports `type: :date` and `type: :datetime`, which are validated as strings in JSON Schema and coerced to `Date` and `Time` before `#call` runs.

## Security and Middleware

VectorMCP keeps security opt-in, but the primitives are built in:

```ruby
server.enable_authentication!(
  strategy: :api_key,
  keys: ["your-secret-key"]
)

server.enable_authorization! do
  authorize_tools do |user, _action, tool|
    user[:role] == "admin" || !tool.name.start_with?("admin_")
  end
end
```

Custom authentication works too:

```ruby
server.enable_authentication!(strategy: :custom) do |request|
  api_key = request[:headers]["X-API-Key"]
  user = User.find_by(api_key: api_key)
  user ? { user_id: user.id, role: user.role } : false
end
```

For MCP clients that speak OAuth 2.1 (e.g. Claude Desktop), pass a `resource_metadata_url:` to turn on RFC 9728 discovery. Unauthenticated requests to `/mcp` return `401` with a `WWW-Authenticate` header pointing at the configured metadata document, and the client drives the rest of the OAuth dance automatically. See [docs/oauth_resource_server.md](./docs/oauth_resource_server.md) for the feature reference and [docs/rails_oauth_integration.md](./docs/rails_oauth_integration.md) for a full Rails + Doorkeeper recipe.

Middleware can hook into tool, resource, prompt, sampling, auth, and transport events, including `before_auth`, `after_auth`, `on_auth_error`, `before_request`, `after_response`, and `on_transport_error`.

See [security/README.md](./security/README.md) for the full security guide.

## Transport Notes

- VectorMCP ships with streamable HTTP as its built-in transport
- `POST /mcp` accepts a single JSON-RPC request, notification, or response; batch arrays are rejected
- `GET /mcp` opens an SSE stream for server-initiated messages
- `DELETE /mcp` terminates the session
- The server advertises MCP protocol `2025-11-25` and accepts `2025-03-26` and `2024-11-05` headers for compatibility
- Default allowed origins are restricted to localhost and loopback addresses

Initialize a session with curl:

```bash
curl -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"curl","version":"1.0"}}}'
```

## More Features

- Roots via `register_root` and `register_root_from_path`
- Image resources and image-aware tools/prompts
- Structured logging with component loggers
- Server-initiated sampling with streaming/tool-call support
- Middleware-driven request shaping and observability

## Documentation

- [CHANGELOG.md](./CHANGELOG.md)
- [examples/](./examples/)
- [docs/rails-setup-guide.md](./docs/rails-setup-guide.md)
- [docs/rails_oauth_integration.md](./docs/rails_oauth_integration.md)
- [docs/oauth_resource_server.md](./docs/oauth_resource_server.md)
- [docs/streamable-http-spec-compliance.md](./docs/streamable-http-spec-compliance.md)
- [security/README.md](./security/README.md)
- [MCP Specification](https://modelcontextprotocol.io/)

## Contributing

Bug reports and pull requests are welcome on [GitHub](https://github.com/sergiobayona/vector_mcp).

## License

Available as open source under the [MIT License](https://opensource.org/licenses/MIT).
