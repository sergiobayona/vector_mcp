# Rails + OAuth 2.1 Integration Guide for VectorMCP

This guide shows how to stand up an MCP server inside a Rails application that
speaks the OAuth 2.1 flow expected by Claude Desktop (and other RFC 9728-aware
MCP clients). The result is a Rails app where end users click "Add custom
connector" in Claude Desktop, get redirected to your Rails login page, sign in
with their real account, and then see every MCP tool call attributed to them.

If you have not yet read the [basic Rails setup guide](rails-setup-guide.md) or
the [OAuth resource server feature reference](oauth_resource_server.md), start
there — this document assumes you are comfortable mounting VectorMCP at `/mcp`
and understand the opt-in `resource_metadata_url:` configuration.

## Table of contents

1. [Architecture](#architecture)
2. [Prerequisites](#prerequisites)
3. [Step 1 — Install Devise and Doorkeeper](#step-1--install-devise-and-doorkeeper)
4. [Step 2 — Configure Doorkeeper for MCP clients](#step-2--configure-doorkeeper-for-mcp-clients)
5. [Step 3 — Serve the protected resource metadata](#step-3--serve-the-protected-resource-metadata)
6. [Step 4 — Wire VectorMCP to Doorkeeper](#step-4--wire-vectormcp-to-doorkeeper)
7. [Step 5 — Attribute tool calls to the authenticated user](#step-5--attribute-tool-calls-to-the-authenticated-user)
8. [Step 6 — End-to-end test with Claude Desktop](#step-6--end-to-end-test-with-claude-desktop)
9. [Operational concerns](#operational-concerns)
10. [Troubleshooting](#troubleshooting)
11. [Security checklist](#security-checklist)

## Architecture

```
┌─────────────────┐       ┌────────────────────────────────────────┐
│ Claude Desktop  │       │  Your Rails app                        │
│   (connector)   │       │                                        │
└────────┬────────┘       │  ┌──────────────────────────────────┐  │
         │ 1. POST /mcp   │  │ Devise (user auth, UI)           │  │
         │    (no token)  │  └──────────────────────────────────┘  │
         ├───────────────▶│                                        │
         │                │  ┌──────────────────────────────────┐  │
         │ 2. 401 +       │  │ Doorkeeper (OAuth 2.1 AS)        │  │
         │   WWW-         │  │  POST /oauth/token               │  │
         │   Authenticate │  │  POST /oauth/revoke              │  │
         │◀───────────────┤  │  GET  /oauth/authorize           │  │
         │                │  │  POST /oauth/applications        │  │
         │ 3. GET         │  │    (Dynamic Client Registration) │  │
         │    .well-known │  │  GET  /.well-known/              │  │
         │                │  │    oauth-authorization-server    │  │
         ├───────────────▶│  └──────────────────────────────────┘  │
         │                │                                        │
         │                │  ┌──────────────────────────────────┐  │
         │                │  │ WellKnownController              │  │
         │ 4. DCR + PKCE  │  │  GET /.well-known/               │  │
         │    flow        │  │    oauth-protected-resource      │  │
         │◀──────────────▶│  └──────────────────────────────────┘  │
         │                │                                        │
         │ 5. POST /mcp   │  ┌──────────────────────────────────┐  │
         │   + Bearer tok │  │ VectorMCP (mounted at /mcp)      │  │
         ├───────────────▶│  │  enable_authentication!(         │  │
         │                │  │    strategy: :custom,            │  │
         │ 6. 200 + tool  │  │    resource_metadata_url: …)     │  │
         │    result      │  │                                  │  │
         │◀───────────────┤  │  Custom strategy asks            │  │
         │                │  │  Doorkeeper::AccessToken to      │  │
         │                │  │  resolve the bearer token.       │  │
         │                │  │                                  │  │
         │                │  │  Tool handler reads              │  │
         │                │  │  session.security_context.user   │  │
         │                │  │  and scopes queries to them.     │  │
         │                │  └──────────────────────────────────┘  │
         └────────────────└────────────────────────────────────────┘
```

**Key design choices:**

- **Rails owns login and token issuance.** Doorkeeper + Devise handle the
  entire OAuth 2.1 flow. VectorMCP never sees passwords.
- **VectorMCP is purely a resource server.** It validates bearer tokens on
  every MCP request by asking Doorkeeper's in-process token table, and maps
  the result to a `User` record.
- **The `/.well-known/oauth-protected-resource` document is served by Rails**,
  not VectorMCP. This keeps the gem simple and lets you use normal Rails
  controllers and tests for the metadata endpoint.
- **In-process token introspection** (calling `Doorkeeper::AccessToken.by_token`
  directly) avoids an HTTP round trip and gives you immediate revocation
  semantics.

## Prerequisites

- Ruby 3.2+
- Rails 7.1+ (Rails 7.2+ recommended)
- Bundler
- A Devise-authenticated `User` model (or willingness to add one)
- A publicly reachable hostname for end-to-end testing. Claude Desktop
  brokers remote connectors through Anthropic's infrastructure, so your
  server must be accessible from the public internet. Use a tunnel (ngrok,
  Cloudflare Tunnel) for local development.

## Step 1 — Install Devise and Doorkeeper

Add to your `Gemfile`:

```ruby
gem "vector_mcp", "~> 0.4"
gem "devise", "~> 4.9"
gem "doorkeeper", "~> 5.7"
# Only needed if you want Doorkeeper to issue JWTs instead of opaque tokens.
# This guide uses opaque tokens + in-process introspection, so you can skip this.
# gem "doorkeeper-jwt", "~> 0.4"
```

Run the installers:

```bash
bundle install
bin/rails generate devise:install
bin/rails generate devise User
bin/rails generate doorkeeper:install
bin/rails generate doorkeeper:migration
bin/rails generate doorkeeper:pkce
bin/rails db:migrate
```

Devise gives you a `User` model and `/users/sign_in`. Doorkeeper adds the
`oauth_applications`, `oauth_access_grants`, and `oauth_access_tokens` tables
and mounts its engine.

## Step 2 — Configure Doorkeeper for MCP clients

Edit `config/initializers/doorkeeper.rb`. The defaults are close to what you
want, but a few settings matter for Claude Desktop:

```ruby
# config/initializers/doorkeeper.rb
Doorkeeper.configure do
  orm :active_record

  # Devise integration: the logged-in user is the resource owner.
  resource_owner_authenticator do
    current_user || warden.authenticate!(scope: :user)
  end

  # --- OAuth 2.1 + PKCE ---

  # PKCE is mandatory for OAuth 2.1 public clients. Claude Desktop uses S256.
  use_pkce_without_secret

  # Only the authorization code flow is needed for OAuth 2.1 public clients.
  grant_flows %w[authorization_code]

  # --- Dynamic Client Registration (RFC 7591) ---

  # Claude Desktop uses DCR to register itself automatically. Enable it and
  # restrict the callback URL to Claude's known value.
  enable_application_owner confirmation: false

  # --- Tokens ---

  # Opaque tokens (the default) work great with in-process introspection.
  # Short-lived access tokens + refresh tokens match Claude Desktop's
  # expectations.
  access_token_expires_in 1.hour
  use_refresh_token
  reuse_access_token

  # --- Scopes ---

  # Tailor these to your MCP tools. Claude Desktop will request `openid mcp`
  # or similar; you pick the names and what they gate.
  default_scopes :mcp
  optional_scopes :mcp_admin

  # --- Redirect URIs ---

  # The Claude Desktop callback. Add others if you also test from other clients.
  # Doorkeeper validates this on both authorize and token endpoints.
  # If DCR is enabled, new clients register their own redirect_uri and
  # Doorkeeper validates it against this pattern.
  # (Doorkeeper accepts https://claude.ai/api/mcp/auth_callback by default
  # since it's an https URI; you don't need force_ssl_in_redirect_uri unless
  # your test setup uses plain http callbacks.)
end
```

Next, enable the Dynamic Client Registration endpoint. Doorkeeper does not
ship DCR out of the box — you need a small controller. If your Doorkeeper
version includes the `doorkeeper-openid_connect` or a DCR extension, use
that. Otherwise, the minimal hand-rolled endpoint below is sufficient for
Claude Desktop:

```ruby
# app/controllers/oauth/dynamic_registrations_controller.rb
module Oauth
  class DynamicRegistrationsController < ActionController::API
    # POST /oauth/register
    def create
      redirect_uris = Array(params[:redirect_uris])
      return render(json: { error: "invalid_redirect_uri" }, status: 400) if redirect_uris.empty?

      application = Doorkeeper::Application.create!(
        name: params[:client_name] || "MCP Client",
        redirect_uri: redirect_uris.join("\n"),
        scopes: params[:scope] || "mcp",
        confidential: false # public client (PKCE only)
      )

      render json: {
        client_id: application.uid,
        # No client_secret — public client using PKCE
        client_id_issued_at: application.created_at.to_i,
        redirect_uris: redirect_uris,
        grant_types: %w[authorization_code refresh_token],
        response_types: %w[code],
        token_endpoint_auth_method: "none",
        scope: application.scopes.to_s
      }, status: :created
    end
  end
end
```

Mount the OAuth engine and the DCR endpoint in your routes (the DCR route
must be outside the Doorkeeper engine since Doorkeeper doesn't provide it):

```ruby
# config/routes.rb
Rails.application.routes.draw do
  devise_for :users
  use_doorkeeper

  # Dynamic Client Registration
  post "/oauth/register", to: "oauth/dynamic_registrations#create"

  # VectorMCP and its metadata endpoint are added in later steps
end
```

## Step 3 — Serve the protected resource metadata

Claude Desktop's first step after receiving the `401` is to `GET
/.well-known/oauth-protected-resource`. That document tells the client where
the authorization server lives.

Add a controller:

```ruby
# app/controllers/well_known_controller.rb
class WellKnownController < ActionController::API
  # GET /.well-known/oauth-protected-resource
  def oauth_protected_resource
    render json: {
      resource: mcp_resource_url,
      authorization_servers: [root_url.chomp("/")],
      bearer_methods_supported: ["header"],
      # Optional but recommended: list the scopes your MCP endpoint understands.
      scopes_supported: %w[mcp mcp_admin],
      resource_documentation: "#{root_url.chomp("/")}/docs"
    }
  end

  private

  def mcp_resource_url
    "#{root_url.chomp("/")}/mcp"
  end
end
```

Route it:

```ruby
# config/routes.rb
Rails.application.routes.draw do
  devise_for :users
  use_doorkeeper
  post "/oauth/register", to: "oauth/dynamic_registrations#create"

  # RFC 9728 protected resource metadata
  get "/.well-known/oauth-protected-resource",
      to: "well_known#oauth_protected_resource"

  # Doorkeeper ships /.well-known/oauth-authorization-server automatically
  # (RFC 8414) via use_doorkeeper. Verify with:
  #   curl https://localhost:3000/.well-known/oauth-authorization-server
end
```

Verify the metadata document with `curl`:

```bash
curl -s https://localhost:3000/.well-known/oauth-protected-resource | jq
curl -s https://localhost:3000/.well-known/oauth-authorization-server | jq
```

Both should return JSON. If the Doorkeeper-provided well-known endpoint is
missing, your Doorkeeper version may not advertise it by default — check
the Doorkeeper release notes for your installed version and either upgrade
or hand-roll it the same way as the protected resource document.

## Step 4 — Wire VectorMCP to Doorkeeper

Now the MCP side. Create an initializer that builds the server, registers a
custom authentication strategy that calls Doorkeeper in-process, and turns
on OAuth resource server mode:

```ruby
# config/initializers/mcp_server.rb
require_relative "../../app/mcp/tools/whoami" # example tool

MCP_SERVER = VectorMCP::Server.new(
  name: Rails.application.class.module_parent_name,
  version: "1.0.0"
)

# Resolve the bearer token by asking Doorkeeper, then load the Rails User.
# Returning a User object (or a Hash) signals "authenticated" to VectorMCP.
# Returning false (or raising) signals "not authenticated".
mcp_oauth_handler = lambda do |request|
  header = request[:headers]["Authorization"] || request[:headers]["authorization"]
  next false unless header&.start_with?("Bearer ")

  token = header.sub(/\ABearer /, "").strip
  next false if token.empty?

  access_token = Doorkeeper::AccessToken.by_token(token)
  next false unless access_token
  next false if access_token.revoked? || access_token.expired?

  # You can pass a required scope here. `nil` means "any scope is fine".
  next false unless access_token.acceptable?(nil)

  user = User.find_by(id: access_token.resource_owner_id)
  next false unless user

  # Returning a Hash keeps SessionContext happy and gives you a neat
  # audit trail. You can embed the User record if you want handlers to
  # reach the full object through session.security_context.user[:record].
  {
    user_id: user.id,
    email: user.email,
    scopes: access_token.scopes.to_a,
    strategy: "doorkeeper_oauth",
    authenticated_at: Time.current,
    record: user
  }
end

MCP_SERVER.enable_authentication!(
  strategy: :custom,
  resource_metadata_url: "#{ENV.fetch("MCP_PUBLIC_URL")}/.well-known/oauth-protected-resource",
  &mcp_oauth_handler
)

# Optional but recommended: authorize individual tools based on scopes.
MCP_SERVER.enable_authorization! do
  authorize_tools do |user, _action, tool|
    next true unless user.is_a?(Hash)

    case tool.name
    when /\Aadmin_/
      user[:scopes].include?("mcp_admin")
    else
      user[:scopes].include?("mcp")
    end
  end
end

MCP_SERVER.register(Whoami)

# Build the Rack app that routes.rb will mount
MCP_APP = MCP_SERVER.rack_app
```

Mount it in `routes.rb`:

```ruby
# config/routes.rb
Rails.application.routes.draw do
  devise_for :users
  use_doorkeeper
  post "/oauth/register", to: "oauth/dynamic_registrations#create"
  get "/.well-known/oauth-protected-resource",
      to: "well_known#oauth_protected_resource"

  mount MCP_APP => "/mcp"
end
```

Set `MCP_PUBLIC_URL` to your public base URL (e.g. your ngrok URL during
development, your production domain in production):

```bash
# .env.development
MCP_PUBLIC_URL=https://lexi-abcdef.ngrok.io
```

## Step 5 — Attribute tool calls to the authenticated user

Inside a tool handler, the authenticated user is available via the session
object's security context. With the Hash shape used above:

```ruby
# app/mcp/tools/whoami.rb
class Whoami < VectorMCP::Tool
  tool_name   "whoami"
  description "Return identifying info about the authenticated user"

  def call(_args, session)
    user_data = session&.security_context&.user
    return "anonymous" unless user_data.is_a?(Hash)

    "Authenticated as #{user_data[:email]} (id=#{user_data[:user_id]}), scopes=#{user_data[:scopes].join(",")}"
  end
end
```

For tools that write to the database, scope every query to the authenticated
user. **Do not trust arguments to identify the user** — always use the value
from the session:

```ruby
# app/mcp/tools/create_note.rb
class CreateNote < VectorMCP::Tool
  tool_name   "create_note"
  description "Create a note for the authenticated user"

  param :title, type: :string, required: true
  param :body,  type: :string, required: true

  def call(args, session)
    user = session&.security_context&.user&.dig(:record)
    raise VectorMCP::UnauthorizedError, "Authentication required" unless user

    note = user.notes.create!(title: args["title"], body: args["body"])
    { id: note.id, created_at: note.created_at.iso8601 }
  end
end
```

The important invariant: **every `ActiveRecord` call that reads or writes
user-scoped data goes through an association rooted at the authenticated
user**, never `Note.create!` or `Note.find(params[:id])`. A missed scope is
a data leak.

## Step 6 — End-to-end test with Claude Desktop

Before connecting from Claude Desktop, confirm each piece works with `curl`:

```bash
# 1. Unauthenticated POST to /mcp returns 401 + WWW-Authenticate
curl -i -X POST "$MCP_PUBLIC_URL/mcp" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"curl","version":"1.0"}}}'

# Expect:
# HTTP/1.1 401 Unauthorized
# WWW-Authenticate: Bearer realm="mcp", resource_metadata="https://.../.well-known/oauth-protected-resource"
# { "jsonrpc":"2.0","id":null,"error":{"code":-32401,"message":"Authentication required"} }

# 2. The metadata document is reachable
curl -s "$MCP_PUBLIC_URL/.well-known/oauth-protected-resource" | jq
curl -s "$MCP_PUBLIC_URL/.well-known/oauth-authorization-server" | jq

# 3. Manual token exchange for smoke testing (optional)
#    a) POST to /oauth/register to get a client_id
#    b) Open /oauth/authorize?client_id=...&response_type=code&code_challenge=...&code_challenge_method=S256&redirect_uri=...
#       in a browser, log in, copy the code from the redirect
#    c) POST to /oauth/token with the code + code_verifier
#    d) Retry /mcp with Authorization: Bearer <access_token>
```

Once all three work, add the connector in Claude Desktop:

1. **Settings → Connectors → Add custom connector**
2. Paste `$MCP_PUBLIC_URL/mcp` as the server URL
3. Leave the "Advanced settings" (Client ID, Client Secret) empty — DCR
   will register the client automatically.
4. Claude opens a browser tab to your Rails `/users/sign_in` page via
   `/oauth/authorize`, you sign in, and grant the requested scopes.
5. Claude completes the PKCE code exchange and returns to the connector
   list with the connector marked as connected.
6. Start a new conversation, enable the connector via the "+" menu, and
   invoke a tool. Verify the tool result reflects the authenticated user.

## Operational concerns

**Public reachability.** Claude Desktop brokers remote connectors
server-side, meaning requests to your MCP server come from Anthropic's
infrastructure, not the user's laptop. If your server is behind a corporate
VPN or only reachable on localhost, Claude cannot connect. Use a tunnel
like ngrok or Cloudflare Tunnel for development, and a proper public
hostname (with valid TLS) in production.

**Token lifetime and refresh.** Doorkeeper's defaults (1-hour access token,
refresh token rotation) match Claude Desktop's expectations. When an access
token expires, Claude automatically uses the refresh token to get a new one
and retries the request. VectorMCP does not need any special handling —
each request is independently authenticated.

**Revocation latency.** Because the custom strategy calls
`Doorkeeper::AccessToken.by_token` on every request, revoking an access
token (e.g. via `Doorkeeper::AccessToken.find(id).revoke`) takes effect
immediately. If you later switch to JWT introspection with caching, be
aware that cached tokens will outlive their revocation until the cache
TTL expires.

**Performance.** The in-process Doorkeeper lookup is a single indexed
`SELECT` on `oauth_access_tokens.token`. For most applications this is
negligible. If you see it in a profiler, options include:

- Caching the `AccessToken → User` mapping in Rails's in-process cache
  with a short TTL (30–60 seconds).
- Switching to signed JWTs and verifying locally with a public key.
- Adding a Rack-level cache in front of `/mcp` keyed on the Authorization
  header. (Be very careful here — stale cached tokens bypass revocation.)

**Logging and audit trail.** VectorMCP logs every 401 challenge and every
auth strategy error via `VectorMCP.logger_for("security")`. Forward these
to your structured logging stack and alert on spikes — repeated 401s from
the same IP can indicate a misconfigured client or credential stuffing.

**Double authentication.** When OAuth mode is on, each authenticated
request runs the custom strategy twice — once at the transport gate,
once inside `VectorMCP::Handlers::Core#authenticate_session!`. For the
Doorkeeper in-process lookup this is an extra indexed SELECT per request.
If it matters, wrap the lookup in a short-lived request-local memoization:

```ruby
mcp_oauth_handler = lambda do |request|
  cache = Thread.current[:mcp_oauth_cache] ||= {}
  header = request[:headers]["Authorization"] || request[:headers]["authorization"]
  return cache[header] if cache.key?(header)

  # ... Doorkeeper lookup ...
  cache[header] = result
end
```

Clear the cache in a Rack middleware after each request.

## Troubleshooting

**`401` from the MCP endpoint even after authenticating via Claude Desktop.**

Check the Rails logs for the `[security]` lines. The most common causes:

- `resource_metadata_url` in the initializer does not match the real
  public URL (typo, trailing slash, wrong scheme). Claude Desktop will
  follow whatever URL is in the `WWW-Authenticate` header, but Doorkeeper
  validates redirect URIs and resource values, so mismatches fail silently.
- The Doorkeeper access token has expired and Claude has not yet refreshed.
  Confirm by invoking a tool twice with a short delay.
- `access_token.acceptable?(nil)` is returning false because the token
  lacks a required scope. Check `access_token.scopes`.

**Claude Desktop says "Unable to connect".**

- Confirm the server is publicly reachable from outside your network:
  `curl -i https://your-tunnel-or-domain/mcp` from a device on a
  different network.
- Confirm TLS is valid. Claude Desktop will not connect over plain HTTP
  (except to `localhost`, which Claude Desktop does not use because of
  server-side brokering).

**`/.well-known/oauth-authorization-server` returns 404.**

Some Doorkeeper versions do not mount this by default. Either upgrade
Doorkeeper, or hand-roll the document in `WellKnownController` using the
Doorkeeper configuration values (authorization_endpoint, token_endpoint,
etc.).

**Dynamic Client Registration fails.**

- Confirm `POST /oauth/register` is routed and returns `201` with a
  `client_id`.
- Confirm the redirect URI from Claude Desktop
  (`https://claude.ai/api/mcp/auth_callback`) is not being rejected by
  `force_ssl_in_redirect_uri` or an application-level validation.

**Tool calls succeed but writes end up on the wrong user.**

Audit every tool handler for queries that don't go through the authenticated
user's association chain. This is the single biggest risk with a multi-user
MCP server — there is no framework protection against `Note.find(params[:id])`
other than discipline and tests.

## Security checklist

Before you ship, confirm all of the following:

- [ ] **HTTPS everywhere.** Production `MCP_PUBLIC_URL` uses HTTPS. The
      `resource_metadata_url` uses HTTPS. Doorkeeper's callback URL
      allowlist only accepts HTTPS (except for `localhost`).
- [ ] **PKCE enforced.** `use_pkce_without_secret` is set in
      `doorkeeper.rb`, so public clients cannot skip PKCE.
- [ ] **DCR restricted.** Your `/oauth/register` controller validates the
      client metadata (e.g. only allow known redirect URIs if you are not
      publicly offering DCR to the world). Consider rate-limiting this
      endpoint via Rack::Attack.
- [ ] **Scopes are checked.** Every tool that performs a privileged
      operation is gated in `authorize_tools`, not just by "is the user
      authenticated".
- [ ] **Queries are user-scoped.** Every `ActiveRecord` read and write in
      a tool handler is rooted at `session.security_context.user`. No
      handler calls `Model.find(params[:id])` without a scope.
- [ ] **Tests cover the denial path.** For each tool, you have a test that
      verifies an unauthorized or incorrectly-scoped user gets rejected —
      not just that the happy path works.
- [ ] **Auth failures are logged and alerted.** 401s, strategy errors,
      and authorization denials flow to your alerting stack.
- [ ] **Rate limiting.** `Rack::Attack` (or equivalent) throttles
      `/oauth/authorize`, `/oauth/token`, `/oauth/register`, and `/mcp`
      per IP and per user.
- [ ] **Token revocation is operational.** You can revoke an access token
      from a Rails console (`Doorkeeper::AccessToken.find_by(token:
      "...").revoke`) and confirm the next MCP request fails.
- [ ] **The `/` health check is still unauthenticated.** VectorMCP leaves
      this endpoint open on purpose so load balancers and uptime monitors
      can probe without credentials. Do not put MCP traffic behind `/`.

## See also

- [`oauth_resource_server.md`](oauth_resource_server.md) — VectorMCP-side
  feature reference
- [`rails-setup-guide.md`](rails-setup-guide.md) — basic Rails mounting
  without OAuth
- [`security/README.md`](../security/README.md) — general security guide
- [Doorkeeper documentation](https://doorkeeper.gitbook.io/guides/)
- [Devise documentation](https://github.com/heartcombo/devise)
- [RFC 9728 — Protected Resource Metadata](https://datatracker.ietf.org/doc/html/rfc9728)
- [RFC 7591 — Dynamic Client Registration](https://datatracker.ietf.org/doc/html/rfc7591)
- [RFC 7636 — PKCE](https://datatracker.ietf.org/doc/html/rfc7636)
