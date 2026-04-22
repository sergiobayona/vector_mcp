# Setting Up a VectorMCP Server Inside a Rails Application

This guide walks through mounting a VectorMCP server as a Rack endpoint inside an existing Rails application. This approach lets you expose MCP tools, resources, and prompts alongside your Rails API without running a separate process.

## Prerequisites

- Ruby 3.2+
- Rails 7.0+ (Rails 7.1+ recommended for native Rack mounting improvements)
- Bundler

## Installation

Add VectorMCP to your Gemfile:

```ruby
gem "vector_mcp", "~> 0.4"
```

Run:

```bash
bundle install
```

## Quick Start

### 1. Define a Tool as a Class

Create `app/mcp/tools/hello.rb`:

```ruby
# app/mcp/tools/hello.rb
class Hello < VectorMCP::Tool
  tool_name   "hello"
  description "Returns a greeting"

  param :name, type: :string, desc: "Name to greet", required: true

  def call(args, _session)
    "Hello, #{args['name']}!"
  end
end
```

VectorMCP ships a class-based DSL (`tool_name`, `description`, `param`) that
generates the JSON Schema for you. The older block-based `register_tool` API
still works and the two styles can coexist.

### 2. Create an MCP Server Initializer

Create `config/initializers/mcp_server.rb`:

```ruby
# config/initializers/mcp_server.rb
require_relative "../../app/mcp/tools/hello"

MCP_SERVER = VectorMCP::Server.new(
  name: "MyRailsApp",
  version: "1.0.0"
)

MCP_SERVER.register(Hello)

# Build the Rack app (does NOT start a server — Rails handles HTTP)
MCP_APP = MCP_SERVER.rack_app
```

### 3. Mount in Routes

Add to `config/routes.rb`:

```ruby
# config/routes.rb
Rails.application.routes.draw do
  mount MCP_APP => "/mcp"

  # ... your other routes
end
```

### 4. Verify It Works

Start your Rails server:

```bash
bin/rails server
```

Initialize an MCP session:

```bash
curl -X POST http://localhost:3000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"curl","version":"1.0"}}}'
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

Tools run inside your Rails process, so they have full access to Active
Record, services, and anything else in your application.

For ActiveRecord-backed tools, inherit from `VectorMCP::Rails::Tool`
instead of `VectorMCP::Tool`. It adds ergonomic helpers for the patterns
that show up in nearly every CRUD tool:

- `find!(Model, id)` — fetch a record or raise `VectorMCP::NotFoundError`
- `respond_with(record, **extras)` — standard success/error payload shape
- `with_transaction { ... }` — wraps the block in an AR transaction
- Auto-rescue of `ActiveRecord::RecordNotFound` → `NotFoundError` and
  `ActiveRecord::RecordInvalid` → error payload
- Arguments are delivered as a `HashWithIndifferentAccess`, so
  `args[:email]` and `args["email"]` both work

`VectorMCP::Rails::Tool` is opt-in — `require "vector_mcp/rails/tool"` to
load it. The core gem has no ActiveRecord dependency.

```ruby
# app/mcp/tools/find_user.rb
require "vector_mcp/rails/tool"

class FindUser < VectorMCP::Rails::Tool
  tool_name   "find_user"
  description "Look up a user by email address"

  param :email, type: :string, desc: "User's email", required: true, format: "email"

  def call(args, _session)
    user = User.find_by(email: args[:email])
    raise VectorMCP::NotFoundError, "User #{args[:email]} not found" unless user

    { id: user.id, name: user.name, email: user.email, created_at: user.created_at }
  end
end
```

```ruby
# app/mcp/tools/search_products.rb
class SearchProducts < VectorMCP::Rails::Tool
  tool_name   "search_products"
  description "Search products by name or category"

  param :query,    type: :string,  desc: "Search term", required: true
  param :category, type: :string,  desc: "Filter by category"
  param :limit,    type: :integer, desc: "Max results", default: 10

  def call(args, _session)
    products = Product.search(args[:query])
    products = products.where(category: args[:category]) if args[:category]
    products.limit(args[:limit] || 10).map do |p|
      { id: p.id, name: p.name, price: p.price.to_f, category: p.category }
    end
  end
end
```

Register them on the server:

```ruby
# config/initializers/mcp_server.rb
require_relative "../../app/mcp/tools/find_user"
require_relative "../../app/mcp/tools/search_products"

MCP_SERVER.register(FindUser, SearchProducts)
```

#### Using `find!` and `respond_with`

The helpers shine most in mutation tools where the "find-or-raise" and
"save-or-errors" patterns repeat. Compare:

```ruby
# Without helpers
class UpdateUser < VectorMCP::Rails::Tool
  tool_name   "update_user"
  description "Update a user's profile"

  param :id,   type: :integer, required: true
  param :name, type: :string

  def call(args, _session)
    user = User.find_by(id: args[:id])
    raise VectorMCP::NotFoundError, "User #{args[:id]} not found" unless user

    if user.update(name: args[:name])
      { success: true, id: user.id, name: user.name }
    else
      { success: false, errors: user.errors.full_messages }
    end
  end
end
```

```ruby
# With helpers
class UpdateUser < VectorMCP::Rails::Tool
  tool_name   "update_user"
  description "Update a user's profile"

  param :id,   type: :integer, required: true
  param :name, type: :string

  def call(args, _session)
    user = find!(User, args[:id])
    user.update(name: args[:name])
    respond_with(user, name: user.name)
  end
end
```

You can also rely on automatic rescue of `ActiveRecord::RecordNotFound`
and `ActiveRecord::RecordInvalid`. This is handy when you want
`User.find(id)` or `User.create!(attrs)` to "just work":

```ruby
class DestroyUser < VectorMCP::Rails::Tool
  tool_name   "destroy_user"
  description "Delete a user"

  param :id, type: :integer, required: true

  def call(args, _session)
    with_transaction do
      user = User.find(args[:id])           # AR::RecordNotFound → NotFoundError
      user.destroy!                         # AR::RecordInvalid  → error payload
      { success: true, id: user.id }
    end
  end
end
```

### Param Types and Coercion

`param :foo, type: :xxx` accepts the usual JSON Schema types plus two
Ruby-native conveniences that auto-coerce client-supplied strings before
your `#call` runs:

| Type        | JSON Schema                             | Handler receives      |
|-------------|-----------------------------------------|-----------------------|
| `:string`   | `{ "type": "string" }`                  | `String`              |
| `:integer`  | `{ "type": "integer" }`                 | `Integer`             |
| `:number`   | `{ "type": "number" }`                  | `Numeric`             |
| `:boolean`  | `{ "type": "boolean" }`                 | `true` / `false`      |
| `:array`    | `{ "type": "array" }`                   | `Array`               |
| `:object`   | `{ "type": "object" }`                  | `Hash`                |
| `:date`     | `{ "type": "string", "format": "date" }`      | `Date`          |
| `:datetime` | `{ "type": "string", "format": "date-time" }` | `Time`          |

`:date` and `:datetime` parse the incoming string via `Date.parse` /
`Time.parse` before the handler sees it. Unparseable input is rejected
with a JSON-RPC `InvalidParamsError` (code `-32602`) — the client sees a
clean "bad request" response instead of a generic internal error.

```ruby
class ExpireSubscription < VectorMCP::Rails::Tool
  tool_name   "expire_subscription"
  description "Mark a subscription as expired on the given date"

  param :id,         type: :integer, required: true
  param :expires_on, type: :date,    required: true

  def call(args, _session)
    subscription = find!(Subscription, args[:id])
    subscription.update(expires_on: args[:expires_on])  # already a Date
    respond_with(subscription)
  end
end
```

Any additional JSON Schema keywords (`enum`, `minimum`, `maximum`,
`pattern`, `format`, `items`, `default`) pass through as keyword
arguments on `param`:

```ruby
param :priority, type: :string, enum: %w[low normal high], default: "normal"
param :score,    type: :number, minimum: 0, maximum: 100
param :email,    type: :string, format: "email"
param :tags,     type: :array,  items: { "type" => "string" }
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

### OAuth 2.1 Resource Server Mode

If your Rails app already issues OAuth tokens (via Doorkeeper, Rodauth-OAuth,
etc.), VectorMCP can advertise itself as an OAuth 2.1 protected resource so
clients like Claude Desktop auto-discover your authorization server and run
the full OAuth + PKCE flow:

```ruby
MCP_SERVER.enable_authentication!(
  strategy: :custom,
  resource_metadata_url: "https://myapp.com/.well-known/oauth-protected-resource"
) do |request|
  token = request[:headers]["Authorization"]&.sub(/\ABearer /, "")
  access_token = Doorkeeper::AccessToken.by_token(token)
  next nil unless access_token&.acceptable?(nil)

  user = User.find(access_token.resource_owner_id)
  { user_id: user.id, role: user.role, scopes: access_token.scopes.to_a }
end
```

With `resource_metadata_url:` set, unauthenticated requests to `/mcp` receive
HTTP `401` with `WWW-Authenticate: Bearer realm="mcp", resource_metadata="<url>"`
(RFC 9728) instead of the default JSON-RPC `-32401` error. The `GET /mcp/health`
endpoint stays unauthenticated.

See [docs/oauth_resource_server.md](oauth_resource_server.md) for the feature
reference and [docs/rails_oauth_integration.md](rails_oauth_integration.md) for
a full Rails + Doorkeeper recipe, including how to serve the required
`.well-known/oauth-protected-resource` metadata document.

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

## Anonymizing Sensitive Data

When your tools return records that contain PII (names, emails, addresses,
account numbers), you often want the LLM to reason about the data without
ever seeing the raw values. VectorMCP ships a token-based anonymization
middleware that rewrites outbound string fields into opaque tokens like
`EMAIL_A1B2C3D4` and automatically restores the original values when a
client echoes a token back in a follow-up tool call.

```ruby
# config/initializers/mcp_server.rb
require "vector_mcp/middleware/anonymizer"
require "vector_mcp/token_store"

TOKEN_STORE = VectorMCP::TokenStore.new

VectorMCP::Middleware::Anonymizer.new(
  store: TOKEN_STORE,
  field_rules: [
    { pattern: /\bname\b/i,  prefix: "NAME"  },
    { pattern: /email/i,     prefix: "EMAIL" },
    { pattern: /phone/i,     prefix: "PHONE" }
  ],
  atomic_keys: /address/i
).install_on(MCP_SERVER)
```

How the rules work:

- `field_rules` — each rule matches a Hash key (case-insensitive by default
  via the regex). Any String value under a matching key is replaced with a
  token whose prefix you control. Arrays inherit the parent key's rule.
- `atomic_keys` — Hash values under a matching key are serialized and
  tokenized as one opaque blob instead of being recursed into. Useful for
  structured-but-indivisible data like addresses, where you don't want
  street/city/zip tokenized separately.

Round-tripping is automatic. If `find_user` returns
`{ email: "EMAIL_A1B2C3D4" }` and the client later calls `send_message`
with `{ to: "EMAIL_A1B2C3D4" }`, the middleware resolves the token back to
the original email before your handler runs. Tokens the store doesn't
recognize pass through unchanged, so clients can't fish for values they
were never shown.

The store is in-memory and per-process. For multi-process deployments (Puma
workers, multiple servers), back it with a shared store by subclassing
`VectorMCP::TokenStore` and overriding `#tokenize`/`#resolve` to read and
write from Redis or your database.

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

For larger applications, give each tool its own class file and collect
the registrations in a single setup module:

```
app/
  mcp/
    tools/
      find_user.rb
      search_users.rb
      update_user.rb
    resources/
      schema_resources.rb
    prompts/
      order_prompts.rb
    setup.rb
```

```ruby
# app/mcp/tools/find_user.rb
require "vector_mcp/rails/tool"

module Mcp
  module Tools
    class FindUser < VectorMCP::Rails::Tool
      tool_name   "find_user"
      description "Look up a user by email address"

      param :email, type: :string, required: true, format: "email"

      def call(args, _session)
        user = User.find_by(email: args[:email])
        raise VectorMCP::NotFoundError, "User #{args[:email]} not found" unless user

        { id: user.id, name: user.name, email: user.email }
      end
    end
  end
end
```

```ruby
# app/mcp/setup.rb
require_relative "tools/find_user"
require_relative "tools/search_users"
require_relative "tools/update_user"
require_relative "resources/schema_resources"
require_relative "prompts/order_prompts"

module Mcp
  module Setup
    TOOLS = [
      Tools::FindUser,
      Tools::SearchUsers,
      Tools::UpdateUser
    ].freeze

    def self.configure(server)
      TOOLS.each { |klass| server.register(klass) }

      Resources::SchemaResources.register(server)
      Prompts::OrderPrompts.register(server)
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

A complete production-ready initializer with a class-based tool:

```ruby
# app/mcp/tools/search_users.rb
require "vector_mcp/rails/tool"

class SearchUsers < VectorMCP::Rails::Tool
  tool_name   "search_users"
  description "Search users by name or email"

  param :query, type: :string,  desc: "Search term", required: true
  param :limit, type: :integer, desc: "Max results", default: 10

  def call(args, _session)
    User.where("name ILIKE :q OR email ILIKE :q", q: "%#{args[:query]}%")
        .limit(args[:limit] || 10)
        .map { |u| { id: u.id, name: u.name, email: u.email } }
  end
end
```

```ruby
# config/initializers/mcp_server.rb
require_relative "../../app/mcp/tools/search_users"

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
MCP_SERVER.register(SearchUsers)

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
