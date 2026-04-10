# Setting Up a VectorMCP Server Inside a Rails Application

This guide walks through mounting a VectorMCP server as a Rack endpoint inside an existing Rails application. This approach lets you expose MCP tools, resources, and prompts alongside your Rails API without running a separate process.

## Prerequisites

- Ruby 3.0.6+
- Rails 7.0+ (Rails 7.1+ recommended for native Rack mounting improvements)
- Bundler

## Installation

Add VectorMCP to your Gemfile:

```ruby
gem "vector_mcp", "~> 0.3"
```

Run:

```bash
bundle install
```

## Quick Start

### 1. Create an MCP Server Initializer

Create `config/initializers/mcp_server.rb`:

```ruby
# config/initializers/mcp_server.rb

MCP_SERVER = VectorMCP::Server.new(
  name: "MyRailsApp",
  version: "1.0.0"
)

# Register a simple tool
MCP_SERVER.register_tool(
  name: "hello",
  description: "Returns a greeting",
  input_schema: {
    type: "object",
    properties: {
      name: { type: "string", description: "Name to greet" }
    },
    required: ["name"]
  }
) do |args, _session|
  "Hello, #{args['name']}!"
end

# Build the Rack app (does NOT start a server — Rails handles HTTP)
MCP_APP = MCP_SERVER.rack_app
```

### 2. Mount in Routes

Add to `config/routes.rb`:

```ruby
# config/routes.rb
Rails.application.routes.draw do
  mount MCP_APP => "/mcp"

  # ... your other routes
end
```

### 3. Verify It Works

Start your Rails server:

```bash
bin/rails server
```

Initialize an MCP session:

```bash
curl -X POST http://localhost:3000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"curl","version":"1.0"}}}'
```

You should receive a JSON response with `serverInfo`, `protocolVersion`, and an `Mcp-Session-Id` header.

## Detailed Setup

### Configuring Transport Options

`rack_app` accepts options that control session management, event retention, and origin validation:

```ruby
MCP_APP = MCP_SERVER.rack_app(
  session_timeout: 600,              # 10 minutes (default: 300)
  event_retention: 200,              # Keep last 200 events for SSE resumability (default: 100)
  allowed_origins: [                 # Origins allowed to connect (default: localhost only)
    "https://myapp.com",
    "https://admin.myapp.com"
  ]
)
```

**Default allowed origins** are restricted to localhost (`http://localhost`, `https://localhost`, `http://127.0.0.1`, etc.). In production, set this to your actual domain(s). Use `["*"]` only for development -- it permits any origin and logs a security warning.

### Registering Tools That Access Rails Models

Tools run inside your Rails process, so they have full access to Active Record, services, and anything else in your application:

```ruby
# config/initializers/mcp_server.rb

MCP_SERVER.register_tool(
  name: "find_user",
  description: "Look up a user by email address",
  input_schema: {
    type: "object",
    properties: {
      email: { type: "string", format: "email" }
    },
    required: ["email"]
  }
) do |args, _session|
  user = User.find_by(email: args["email"])
  if user
    { id: user.id, name: user.name, email: user.email, created_at: user.created_at }
  else
    { error: "User not found" }
  end
end

MCP_SERVER.register_tool(
  name: "search_products",
  description: "Search products by name or category",
  input_schema: {
    type: "object",
    properties: {
      query: { type: "string" },
      category: { type: "string" },
      limit: { type: "integer", default: 10 }
    },
    required: ["query"]
  }
) do |args, _session|
  products = Product.search(args["query"])
  products = products.where(category: args["category"]) if args["category"]
  products.limit(args["limit"] || 10).map do |p|
    { id: p.id, name: p.name, price: p.price.to_f, category: p.category }
  end
end
```

### Registering Resources

Resources expose read-only data to MCP clients:

```ruby
MCP_SERVER.register_resource(
  uri: "app://schema/users",
  name: "User Schema",
  description: "The database schema for the users table",
  mime_type: "application/json"
) do |_params, _session|
  columns = User.columns.map { |c| { name: c.name, type: c.type, nullable: c.null } }
  { table: "users", columns: columns }.to_json
end

MCP_SERVER.register_resource(
  uri: "app://stats/overview",
  name: "Application Stats",
  description: "Current application statistics",
  mime_type: "application/json"
) do |_params, _session|
  {
    users_count: User.count,
    products_count: Product.count,
    orders_today: Order.where("created_at >= ?", Date.current).count
  }.to_json
end
```

### Registering Prompts

Prompts are reusable templates for LLM interactions:

```ruby
MCP_SERVER.register_prompt(
  name: "summarize_order",
  description: "Generates a summary of a customer order",
  arguments: [
    { name: "order_id", description: "The order ID to summarize", required: true }
  ]
) do |args, _session|
  order = Order.includes(:line_items, :customer).find(args["order_id"])

  {
    messages: [
      {
        role: "user",
        content: {
          type: "text",
          text: "Summarize this order:\n" \
                "Customer: #{order.customer.name}\n" \
                "Items: #{order.line_items.map { |li| "#{li.product_name} x#{li.quantity}" }.join(', ')}\n" \
                "Total: $#{order.total}\n" \
                "Status: #{order.status}"
        }
      }
    ]
  }
end
```

## Authentication

### API Key Authentication

Protect your MCP endpoint with API key authentication:

```ruby
# config/initializers/mcp_server.rb

MCP_SERVER.enable_authentication!(
  strategy: :api_key,
  keys: [
    Rails.application.credentials.mcp_api_key,
    ENV["MCP_API_KEY"]
  ].compact
)
```

Clients include the key in the `Authorization` header:

```bash
curl -X POST http://localhost:3000/mcp \
  -H "Authorization: Bearer your-api-key" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{...}}'
```

### JWT Authentication

For stateless authentication in distributed systems:

```ruby
MCP_SERVER.enable_authentication!(
  strategy: :jwt_token,
  secret: Rails.application.credentials.mcp_jwt_secret,
  algorithm: "HS256"
)
```

### Custom Authentication (e.g., Devise Integration)

Use a custom strategy to integrate with your existing authentication system:

```ruby
MCP_SERVER.enable_authentication!(strategy: :custom) do |request|
  token = request[:headers]["Authorization"]&.delete_prefix("Bearer ")
  return nil unless token

  # Look up the user however your app does it
  api_token = ApiToken.find_by(token: token)
  return nil unless api_token&.active?

  # Return a user hash — this becomes available in tool handlers via session context
  { user_id: api_token.user_id, role: api_token.role, permissions: api_token.permissions }
end
```

### Authorization Policies

Control which users can access which tools and resources:

```ruby
MCP_SERVER.enable_authorization! do
  authorize_tools do |user, _action, tool|
    case tool.name
    when "delete_user", "run_migration"
      user[:role] == "admin"
    else
      true
    end
  end

  authorize_resources do |user, _action, resource|
    # Only allow reading financial data for finance role
    if resource.uri.start_with?("app://finance/")
      user[:permissions]&.include?("finance:read")
    else
      true
    end
  end
end
```

## Graceful Shutdown

Clean up MCP sessions and streaming connections when Rails shuts down:

```ruby
# config/initializers/mcp_server.rb

at_exit do
  MCP_SERVER.transport&.stop
end
```

For Puma specifically, add to `config/puma.rb`:

```ruby
# config/puma.rb

on_worker_shutdown do
  MCP_SERVER.transport&.stop
end
```

## Logging

VectorMCP uses its own structured logging system, configured via environment variables:

```bash
# Development: verbose text output
VECTORMCP_LOG_LEVEL=DEBUG bin/rails server

# Production: JSON structured logging to file
VECTORMCP_LOG_LEVEL=INFO \
VECTORMCP_LOG_FORMAT=json \
VECTORMCP_LOG_OUTPUT=file \
VECTORMCP_LOG_FILE=/var/log/myapp/mcp.log \
bin/rails server
```

Available settings:

| Variable | Values | Default |
|----------|--------|---------|
| `VECTORMCP_LOG_LEVEL` | `DEBUG`, `INFO`, `WARN`, `ERROR`, `FATAL` | `INFO` |
| `VECTORMCP_LOG_FORMAT` | `text`, `json` | `text` |
| `VECTORMCP_LOG_OUTPUT` | `stderr`, `stdout`, `file` | `stderr` |
| `VECTORMCP_LOG_FILE` | File path | `./vectormcp.log` |

## Production Considerations

### Origin Validation

Always configure explicit allowed origins in production:

```ruby
MCP_APP = MCP_SERVER.rack_app(
  allowed_origins: [ENV.fetch("MCP_ALLOWED_ORIGIN", "https://myapp.com")]
)
```

### Session Timeouts

Adjust session timeout based on your use case:

```ruby
MCP_APP = MCP_SERVER.rack_app(
  session_timeout: 1800  # 30 minutes for long-running LLM interactions
)
```

### Health Checks

The mounted MCP app exposes a health check at `/mcp/health`:

```bash
curl http://localhost:3000/mcp/health
# => {"status":"ok"}
```

Use this for load balancer health checks and monitoring.

### Thread Safety

VectorMCP uses `concurrent-ruby` for thread-safe session management and event storage. It is safe to use with multi-threaded servers like Puma. No additional configuration is needed.

### Extracting MCP Setup to a Dedicated File

For larger applications, move tool registrations out of the initializer:

```
app/
  mcp/
    tools/
      user_tools.rb
      product_tools.rb
    resources/
      schema_resources.rb
    prompts/
      order_prompts.rb
    setup.rb
```

```ruby
# app/mcp/setup.rb
module Mcp
  module Setup
    def self.configure(server)
      Tools::UserTools.register(server)
      Tools::ProductTools.register(server)
      Resources::SchemaResources.register(server)
      Prompts::OrderPrompts.register(server)
    end
  end
end
```

```ruby
# app/mcp/tools/user_tools.rb
module Mcp
  module Tools
    module UserTools
      def self.register(server)
        server.register_tool(
          name: "find_user",
          description: "Look up a user by email",
          input_schema: {
            type: "object",
            properties: { email: { type: "string" } },
            required: ["email"]
          }
        ) do |args, _session|
          user = User.find_by(email: args["email"])
          user ? { id: user.id, name: user.name } : { error: "Not found" }
        end
      end
    end
  end
end
```

```ruby
# config/initializers/mcp_server.rb
require_relative "../../app/mcp/setup"

MCP_SERVER = VectorMCP::Server.new(name: "MyRailsApp", version: "1.0.0")
Mcp::Setup.configure(MCP_SERVER)
MCP_APP = MCP_SERVER.rack_app
```

## Full Example Initializer

A complete production-ready initializer:

```ruby
# config/initializers/mcp_server.rb

MCP_SERVER = VectorMCP::Server.new(
  name: Rails.application.class.module_parent_name,
  version: "1.0.0"
)

# --- Authentication ---
if Rails.env.production?
  MCP_SERVER.enable_authentication!(
    strategy: :api_key,
    keys: [Rails.application.credentials.mcp_api_key]
  )
end

# --- Tools ---
MCP_SERVER.register_tool(
  name: "search_users",
  description: "Search users by name or email",
  input_schema: {
    type: "object",
    properties: {
      query: { type: "string", description: "Search term" },
      limit: { type: "integer", description: "Max results", default: 10 }
    },
    required: ["query"]
  }
) do |args, _session|
  User.where("name ILIKE :q OR email ILIKE :q", q: "%#{args['query']}%")
      .limit(args["limit"] || 10)
      .map { |u| { id: u.id, name: u.name, email: u.email } }
end

# --- Resources ---
MCP_SERVER.register_resource(
  uri: "app://stats",
  name: "App Stats",
  description: "Application statistics",
  mime_type: "application/json"
) do |_params, _session|
  { users: User.count, uptime: (Time.current - Rails.application.initialized_at).to_i }.to_json
end

# --- Build Rack App ---
MCP_APP = MCP_SERVER.rack_app(
  session_timeout: Rails.env.production? ? 600 : 300,
  allowed_origins: Rails.env.production? ? [ENV.fetch("MCP_ALLOWED_ORIGIN")] : ["*"]
)

# --- Cleanup ---
at_exit { MCP_SERVER.transport&.stop }
```

## MCP Protocol Flow

For reference, here is the typical request flow when an MCP client connects to your Rails-mounted endpoint:

1. **Initialize** -- Client sends `POST /mcp` with `initialize` method (no session ID needed). Server returns capabilities and an `Mcp-Session-Id` header.
2. **Initialized** -- Client sends `POST /mcp` with `notifications/initialized` and the session ID. Server returns `202 Accepted`.
3. **Streaming (optional)** -- Client opens `GET /mcp` with the session ID for server-sent events (notifications, sampling requests).
4. **Requests** -- Client sends tool calls, resource reads, and prompt requests via `POST /mcp` with the session ID.
5. **Termination** -- Client sends `DELETE /mcp` with the session ID to end the session.
