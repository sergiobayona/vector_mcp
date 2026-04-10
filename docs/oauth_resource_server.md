# OAuth 2.1 Resource Server Mode

VectorMCP's HTTP Stream transport can act as an **OAuth 2.1 protected resource
server** per [RFC 9728 (Protected Resource Metadata)][rfc9728]. When enabled,
unauthenticated requests to the MCP endpoint return HTTP `401` with a
`WWW-Authenticate` header that points MCP clients at your authorization server,
so they can run a standard OAuth 2.1 + PKCE flow and retry the request with a
bearer token.

This is the mechanism [Claude Desktop][claude-mcp-auth] (and any other
RFC 9728-aware MCP client) uses to discover and authenticate against remote
custom connectors.

[rfc9728]: https://datatracker.ietf.org/doc/html/rfc9728
[claude-mcp-auth]: https://support.anthropic.com/en/articles/11510644-custom-connectors-via-remote-mcp-servers

## What this feature does

- Adds a transport-level authentication gate on `POST`, `GET`, and `DELETE`
  `/mcp` that runs before JSON-RPC dispatch.
- On an unauthenticated request, returns:
  ```
  HTTP/1.1 401 Unauthorized
  Content-Type: application/json
  WWW-Authenticate: Bearer realm="mcp", resource_metadata="<your url>"
  ```
  with a JSON-RPC error envelope in the body (`code: -32401`,
  `message: "Authentication required"`) for clients that also parse bodies.
- Leaves the `GET /` health check endpoint unauthenticated so operators can
  probe liveness without credentials.
- Logs each 401 challenge via `VectorMCP.logger_for("security")` at `info`
  level for auditability.

## What this feature does *not* do

VectorMCP is only the **resource server** in an OAuth 2.1 deployment. It does
not:

- Serve the `/.well-known/oauth-protected-resource` or
  `/.well-known/oauth-authorization-server` metadata documents. Your
  application (e.g. the Rails app mounting VectorMCP) is responsible for these.
- Implement the authorization server itself — login UI, PKCE token issuance,
  dynamic client registration, token refresh, or revocation. Use Doorkeeper,
  Keycloak, Auth0, or any RFC-compliant OAuth 2.1 provider for that.
- Parse or validate tokens. That work belongs to your configured
  authentication strategy (`:jwt`, `:custom`, etc.).

For a full end-to-end wiring of Rails + Devise + Doorkeeper + VectorMCP, see
[`rails_oauth_integration.md`](rails_oauth_integration.md).

## Enabling the feature

Pass `resource_metadata_url:` to `enable_authentication!`:

```ruby
server.enable_authentication!(
  strategy: :custom,
  resource_metadata_url: "https://app.example.com/.well-known/oauth-protected-resource"
) do |request|
  token = request[:headers]["Authorization"]&.sub(/\ABearer /, "")
  next false unless token

  access_token = Doorkeeper::AccessToken.by_token(token)
  next false unless access_token&.acceptable?(nil)

  User.find(access_token.resource_owner_id)
end
```

The URL you pass is the one advertised in the `WWW-Authenticate` header's
`resource_metadata` parameter. Point it at the document *your application*
serves that describes where to find the authorization server.

## Opt-in, zero default change

This feature is strictly opt-in:

- When `resource_metadata_url` is omitted, VectorMCP's behavior is unchanged.
  Unauthenticated tool calls continue to surface as JSON-RPC `-32401` errors
  at HTTP `200`, exactly as in 0.4.x and earlier.
- When `resource_metadata_url` is set, VectorMCP only adds the `401`/header
  response. It does not change how authenticated requests are processed or
  how tool handlers access the user.

This keeps existing internal deployments (API-key-protected servers that
aren't doing OAuth) fully unaffected.

## Requirements and caveats

- **HTTP Stream transport only.** Stdio has no HTTP status codes, so the
  feature is a no-op there.
- **Configure a strategy that speaks bearer tokens.** `:custom` with an
  introspection handler is the typical choice. `:jwt` works for locally
  verifiable tokens (HS256 shared secret). `:api_key` technically accepts
  `Authorization: Bearer <key>` but is not an OAuth flow.
- **HTTPS is strongly recommended** for the metadata URL. VectorMCP logs a
  warning when the URL is not HTTPS, but does not raise — plaintext is
  acceptable for local development (`http://localhost/...`).
- **Claude Desktop brokers remote connectors server-side**, which means your
  server must be reachable from Anthropic's infrastructure, not just from
  your laptop. Use a public hostname or a tunnel (e.g. ngrok) for end-to-end
  testing.
- **Double authentication for authenticated requests.** The transport gate
  runs the authentication strategy, and the existing per-operation checks in
  `VectorMCP::Handlers::Core` (e.g. `authenticate_session!` on `tools/call`)
  run it again. For API keys and JWTs this is negligible. If your strategy
  makes a network call on each authentication, consider caching within the
  strategy itself.

## How it composes with the existing security pipeline

The OAuth gate does not replace the existing authentication/authorization
pipeline — it sits in front of it:

1. **Origin check** (`valid_origin?`) — unchanged.
2. **OAuth gate** (new) — if `oauth_resource_server_enabled?` and the request
   is unauthenticated, return `401` + `WWW-Authenticate` immediately.
3. **Method dispatch** — `POST`, `GET`, `DELETE` handlers run normally.
4. **Handler-layer authorization** — `VectorMCP::Handlers::Core#call_tool`,
   `#read_resource`, etc. continue to call `authenticate_session!` and
   `authorize_action!`. These checks are unchanged, so your existing
   authorization policies continue to work.

If `resource_metadata_url` is not set, step 2 is skipped entirely.

## Logging

Each `401` challenge is logged to `VectorMCP.logger_for("security")` at
`info` level:

```
[INFO] [security] OAuth 401 challenge issued for POST /mcp
```

Authentication strategy errors raised during the transport gate are caught
and logged at `warn` level, then treated as "unauthenticated" (rather than
propagated as a 500):

```
[WARN] [security] OAuth transport auth strategy raised <ErrorClass>: <message>
```

This prevents a malformed or expired token from crashing the request pipeline.

## See also

- [`rails_oauth_integration.md`](rails_oauth_integration.md) — step-by-step
  Rails + Devise + Doorkeeper + VectorMCP recipe
- [`security/README.md`](../security/README.md) — general security guide
- [RFC 9728](https://datatracker.ietf.org/doc/html/rfc9728) — OAuth 2.0
  Protected Resource Metadata
- [MCP Authorization spec](https://modelcontextprotocol.io/) — the MCP
  project's OAuth guidance
