# Streamable HTTP Transport: Specification Compliance Audit

**Specification:** [MCP Streamable HTTP Transport (2025-11-25)](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#streamable-http)
**Implementation:** VectorMCP Ruby Gem
**Date:** 2026-04-09

---

## Table of Contents

- [Executive Summary](#executive-summary)
- [Specification Overview](#specification-overview)
- [Findings Summary](#findings-summary)
- [Missing Implementations](#missing-implementations)
  - [1. MCP-Protocol-Version Header Not Implemented](#1-mcp-protocol-version-header-not-implemented)
  - [2. Notifications Return Wrong HTTP Status](#2-notifications-return-wrong-http-status)
  - [3. SSE Priming Event Missing](#3-sse-priming-event-missing)
  - [4. SSE retry Field Never Sent](#4-sse-retry-field-never-sent)
- [Incorrect Interpretations](#incorrect-interpretations)
  - [5. Batch Request Support Violates Spec](#5-batch-request-support-violates-spec)
  - [6. broadcast_message Violates No-Broadcast Rule](#6-broadcast_message-violates-no-broadcast-rule)
  - [7. POST Accept Header Validation Too Lenient](#7-post-accept-header-validation-too-lenient)
  - [8. Event IDs Lack Stream Origin Information](#8-event-ids-lack-stream-origin-information)
  - [9. No Distinction Between POST SSE and GET SSE Streams](#9-no-distinction-between-post-sse-and-get-sse-streams)
- [Potential Issues](#potential-issues)
  - [10. Protocol Version Hardcoded to 2024-11-05](#10-protocol-version-hardcoded-to-2024-11-05)
  - [11. Non-Standard SSE Events and JSON-RPC Methods](#11-non-standard-sse-events-and-json-rpc-methods)
  - [12. POST SSE Response Is Non-Streaming](#12-post-sse-response-is-non-streaming)
  - [13. Origin Validation Error Response Format](#13-origin-validation-error-response-format)
- [Compliant Implementations](#compliant-implementations)
- [Priority Matrix](#priority-matrix)

---

## Executive Summary

This document audits VectorMCP's Streamable HTTP Transport implementation against the MCP specification version 2025-11-25. The audit identified **13 findings**: 4 missing implementations (now resolved), 5 incorrect interpretations, and 4 potential issues (1 now resolved).

**0 remaining HIGH severity** MUST-level spec violations.

**Resolved since initial audit (2026-04-09):**
1. ~~The `MCP-Protocol-Version` header is completely unimplemented.~~ **FIXED** -- Header validation added to POST, GET, and DELETE handlers. Unsupported versions return 400. Missing header assumes `2025-03-26` for backwards compatibility.
2. ~~Client notifications incorrectly return HTTP 200 instead of 202.~~ **FIXED** -- Notifications (method + no id) now return 202 Accepted with empty body.
3. ~~No SSE priming event with empty data.~~ **FIXED** -- Priming event (event ID + empty data) sent before all SSE streams (GET and POST).
4. ~~No SSE `retry` field support.~~ **FIXED** -- `format_sse_event` supports `retry_ms:` parameter. `keep_alive_loop` sends `retry: 5000` before intentional disconnections.
5. ~~Protocol version hardcoded to `2024-11-05`.~~ **FIXED** -- Updated to `2025-03-26` with `SUPPORTED_PROTOCOL_VERSIONS` constant.
6. ~~Non-standard `connection/established` SSE event.~~ **FIXED** -- Replaced with spec-compliant empty-data priming event.
7. ~~`broadcast_message` sends same message to multiple streams.~~ **FIXED** -- Removed `broadcast_message` and `broadcast_notification` entirely. `capabilities.rb` now uses `send_notification` (single-session) only.
8. ~~Batch JSON-RPC support contradicts single-message requirement.~~ **FIXED** -- Array POST bodies now rejected with 400. `handle_batch_request`, `process_batch_item`, and `batch_invalid_item_error` removed.
9. ~~Event IDs lack stream origin for proper replay scoping.~~ **FIXED** -- Added `stream_id` to `Event` struct and `EventStore`. Events are stored with stream-scoped IDs. Replay filters by `session_id` only (not `stream_id`) to preserve resumability across reconnections.
10. ~~No POST/GET stream distinction for response restrictions.~~ **FIXED** -- Added `origin` and `stream_id` fields to `StreamingConnection`. `send_message_to_session` blocks JSON-RPC responses on GET streams per spec.
11. ~~POST Accept validation doesn't require `text/event-stream`.~~ **FIXED** -- `valid_post_accept?` now requires both `application/json` AND `text/event-stream` when Accept header is present. `*/*` and missing header still accepted for backwards compatibility.
12. ~~Non-standard heartbeat SSE events.~~ **FIXED** -- Heartbeats now use SSE comments (`": heartbeat\n\n"`) instead of JSON-RPC notifications. No longer stored in event store.
13. ~~Origin error uses plain text instead of JSON-RPC error.~~ **FIXED** -- `forbidden_response` now returns JSON-RPC error object with `application/json` content type.

The implementation correctly handles session ID assignment, session lifecycle (creation, validation, termination), origin validation, DELETE requests, outgoing response detection, protocol version header validation, notification responses, SSE priming, and SSE retry guidance.

---

## Specification Overview

The MCP Streamable HTTP Transport (2025-11-25) defines how an MCP server exposes a **single HTTP endpoint** (the "MCP endpoint") supporting POST, GET, and DELETE methods:

- **POST**: Clients send a single JSON-RPC request, notification, or response. The server responds with `application/json` or `text/event-stream`.
- **GET**: Clients open an SSE stream for server-initiated messages. The server returns `text/event-stream` or `405 Method Not Allowed`.
- **DELETE**: Clients terminate sessions.

Key requirements include:
- Sessions managed via `MCP-Session-Id` header
- `MCP-Protocol-Version` header on all client requests after initialization
- No broadcasting of the same message across multiple streams
- SSE streams primed with an empty-data event carrying an event ID
- SSE `retry` field sent before server-initiated disconnections
- Resumability via `Last-Event-ID` with stream-scoped event replay
- Origin header validation on all connections

---

## Findings Summary

| # | Finding | Category | Severity | Spec Level | Status |
|---|---------|----------|----------|-----------|--------|
| 1 | `MCP-Protocol-Version` header not implemented | Missing | **HIGH** | MUST | **FIXED** |
| 2 | Notifications return 200 instead of 202 | Missing | **HIGH** | MUST | **FIXED** |
| 3 | No SSE priming event with empty data | Missing | MEDIUM | SHOULD | **FIXED** |
| 4 | No SSE `retry` field support | Missing | MEDIUM | SHOULD | **FIXED** |
| 5 | Batch support violates single-message requirement | Incorrect | **HIGH** | MUST | **FIXED** |
| 6 | `broadcast_message` sends same message to multiple streams | Incorrect | **HIGH** | MUST | **FIXED** |
| 7 | POST Accept validation doesn't require `text/event-stream` | Incorrect | MEDIUM | MUST (client) | **FIXED** |
| 8 | Event IDs lack stream origin for proper replay scoping | Incorrect | MEDIUM | SHOULD/MUST | **FIXED** |
| 9 | No POST/GET stream distinction for response restrictions | Incorrect | MEDIUM | MUST | **FIXED** |
| 10 | Protocol version stuck at `2024-11-05` | Potential | MEDIUM | -- | **FIXED** |
| 11 | Non-standard SSE events and JSON-RPC methods | Potential | LOW | -- | **FIXED** |
| 12 | POST SSE is single-event, no interim messages | Potential | LOW | MAY | Open |
| 13 | Origin error uses plain text instead of JSON-RPC error | Potential | LOW | MAY | **FIXED** |

---

## Missing Implementations

### 1. MCP-Protocol-Version Header Not Implemented

**Severity:** HIGH | **Spec Level:** MUST | **Status: FIXED**

#### Spec Reference

**Section:** Streamable HTTP > Protocol Version Header
**URL:** https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#protocol-version-header

The full normative text from the specification:

> If using HTTP, the client **MUST** include the `MCP-Protocol-Version: <protocol-version>` HTTP header on all subsequent requests to the MCP server, allowing the MCP server to respond based on the MCP protocol version.
>
> For example: `MCP-Protocol-Version: 2025-11-25`
>
> The protocol version sent by the client **SHOULD** be the one [negotiated during initialization](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle#version-negotiation).
>
> For backwards compatibility, if the server does *not* receive an `MCP-Protocol-Version` header, and has no other way to identify the version - for example, by relying on the protocol version negotiated during initialization - the server **SHOULD** assume protocol version `2025-03-26`.
>
> If the server receives a request with an invalid or unsupported `MCP-Protocol-Version`, it **MUST** respond with `400 Bad Request`.

#### Resolution

**Fixed in commit on 2026-04-09.** Implementation:

- `PROTOCOL_VERSION` updated to `"2025-03-26"` and `SUPPORTED_PROTOCOL_VERSIONS = %w[2025-03-26 2024-11-05]` added to `VectorMCP::Server`
- `validate_protocol_version_header(env)` added to `HttpStream` -- returns nil if valid, 400 Rack response if unsupported
- Validation integrated into `handle_post_request` (skipped for `initialize`), `handle_get_request`, and `handle_delete_request`
- Missing header is allowed for backwards compatibility (assumes `2025-03-26` per spec)
- 7 unit tests added covering valid, unsupported, missing, and initialize-bypass scenarios

#### Files Changed

- `lib/vector_mcp/server.rb` — Updated `PROTOCOL_VERSION`, added `SUPPORTED_PROTOCOL_VERSIONS`
- `lib/vector_mcp/transport/http_stream.rb` — Added `validate_protocol_version_header`, integrated into all 3 handlers

---

### 2. Notifications Return Wrong HTTP Status

**Severity:** HIGH | **Spec Level:** MUST | **Status: FIXED**

#### Spec Reference

**Section:** Streamable HTTP > Sending Messages to the Server, item 4
**URL:** https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#sending-messages-to-the-server

The full normative text from the specification:

> 4\. If the input is a JSON-RPC *response* or *notification*:
>    * If the server accepts the input, the server **MUST** return HTTP status code 202 Accepted with no body.
>    * If the server cannot accept the input, it **MUST** return an HTTP error status code (e.g., 400 Bad Request). The HTTP response body **MAY** comprise a JSON-RPC *error response* that has no `id`.

This is also confirmed in the specification's sequence diagram, which shows:

> ```
> Client->>+Server: POST ... notification/response ...  MCP-Session-Id: 1868a90c...
> Server->>-Client: 202 Accepted
> ```

#### Current Behavior

In `handle_single_request` (`lib/vector_mcp/transport/http_stream.rb:371-378`):

```ruby
def handle_single_request(message, session, env)
  if outgoing_response?(message)
    handle_outgoing_response(message)
    return [202, { "Mcp-Session-Id" => session.id }, []]
  end

  result = @server.handle_message(message, session.context, session.id)
  build_rpc_response(env, result, message["id"], session.id)
end
```

#### Resolution

**Fixed in commit on 2026-04-09.** Implementation:

- Added notification detection in `handle_single_request`: messages with `method` and no `id` key now return 202 Accepted with empty body
- The notification handler is still called via `@server.handle_message` before returning 202
- Uses `!message.key?("id")` for precise detection (absence of key, not nil value)
- `Mcp-Session-Id` header is still included on 202 responses
- 4 unit tests added covering 202 response, header presence, handler execution, and request vs notification distinction

#### Files Changed

- `lib/vector_mcp/transport/http_stream.rb` — Modified `handle_single_request`

---

### 3. SSE Priming Event Missing

**Severity:** MEDIUM | **Spec Level:** SHOULD | **Status: FIXED**

#### Spec Reference

**Section:** Streamable HTTP > Sending Messages to the Server, item 6, sub-item 1
**URL:** https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#sending-messages-to-the-server

The full normative text from the specification:

> 6\. If the server initiates an SSE stream:
>    * The server **SHOULD** immediately send an SSE event consisting of an event ID and an empty `data` field in order to prime the client to reconnect (using that event ID as `Last-Event-ID`).
>    * After the server has sent an SSE event with an event ID to the client, the server **MAY** close the *connection* (without terminating the *SSE stream*) at any time in order to avoid holding a long-lived connection. The client **SHOULD** then "poll" the SSE stream by attempting to reconnect.

This requirement applies to SSE streams initiated from both POST responses (item 6) and GET responses. The GET section (Listening for Messages from the Server, item 4) cross-references the same polling behavior:

> If the server closes the *connection* without terminating the *stream*, it **SHOULD** follow the same polling behavior as described for POST requests: sending a `retry` field and allowing the client to reconnect.

#### Current Behavior

#### Resolution

**Fixed in commit on 2026-04-09.** Implementation:

- **GET SSE streams**: Replaced `connection/established` JSON-RPC notification with spec-compliant priming event (`id: <event_id>\ndata:\n\n`). The priming event is stored in the event store for resumability.
- **POST SSE responses**: `sse_rpc_response` and `sse_error_response` now prepend a priming event before the actual data event in the response body.
- Priming events use `nil` for event type (no `event:` line) so they fire the default `onmessage` handler in EventSource.
- 5 unit tests added across stream_handler_spec and http_stream_spec.

#### Files Changed

- `lib/vector_mcp/transport/http_stream.rb` — Modified `sse_rpc_response` and `sse_error_response`
- `lib/vector_mcp/transport/http_stream/stream_handler.rb` — Modified `stream_to_client`

---

### 4. SSE `retry` Field Never Sent

**Severity:** MEDIUM | **Spec Level:** SHOULD | **Status: FIXED**

#### Spec Reference

**Section:** Streamable HTTP > Sending Messages to the Server, item 6, sub-item 3
**URL:** https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#sending-messages-to-the-server

The full normative text from the specification:

> 6\. If the server initiates an SSE stream:
>    * [...]
>    * If the server does close the *connection* prior to terminating the *SSE stream*, it **SHOULD** send an SSE event with a standard [`retry`](https://html.spec.whatwg.org/multipage/server-sent-events.html#:~:text=field%20name%20is%20%22retry%22) field before closing the connection. The client **MUST** respect the `retry` field, waiting the given number of milliseconds before attempting to reconnect.

The same requirement is echoed for GET SSE streams in Listening for Messages from the Server, item 4:

> If the server closes the *connection* without terminating the *stream*, it **SHOULD** follow the same polling behavior as described for POST requests: sending a `retry` field and allowing the client to reconnect.

The `retry` field is a standard SSE mechanism defined in the [WHATWG HTML Living Standard](https://html.spec.whatwg.org/multipage/server-sent-events.html). When present, it sets the EventSource reconnection time in milliseconds.

#### Current Behavior

#### Resolution

**Fixed in commit on 2026-04-09.** Implementation:

- Added `retry_ms:` keyword argument to both `format_sse_event` methods (in `stream_handler.rb` and `http_stream.rb`). When provided, emits `retry: <ms>` line in the SSE event.
- Added `DEFAULT_RETRY_MS = 5000` constant to `StreamHandler`.
- `keep_alive_loop` sends `retry: 5000\n\n` before breaking on max duration (5 minutes), guiding clients to reconnect after 5 seconds.
- 2 unit tests added for `format_sse_event` with and without `retry_ms`.

#### Files Changed

- `lib/vector_mcp/transport/http_stream/stream_handler.rb` — Added `DEFAULT_RETRY_MS`, updated `format_sse_event` and `keep_alive_loop`
- `lib/vector_mcp/transport/http_stream.rb` — Updated `format_sse_event`

---

## Incorrect Interpretations

### 5. Batch Request Support Violates Spec

**Severity:** HIGH | **Spec Level:** MUST | **Status: FIXED**

#### Spec Requirement

> The body of the POST request **MUST** be a **single** JSON-RPC request, notification, or response.

#### Resolution

**Fixed on 2026-04-09.** Implementation:

- Array POST bodies are now rejected early in `handle_post_request` with a 400 JSON-RPC error (code -32600, "Invalid Request") before session resolution
- Removed dead code: `handle_batch_request`, `process_batch_item`, and `batch_invalid_item_error` methods
- Cleaned up `resolve_session_for_post` to remove array handling logic
- 2 tests: rejection of non-empty arrays and empty arrays, plus existing test confirming single objects still work
- 6 old batch behavior tests replaced

#### Files Changed

- `lib/vector_mcp/transport/http_stream.rb` — Reject arrays in `handle_post_request`, remove batch methods, simplify `resolve_session_for_post`
- `spec/vector_mcp/transport/http_stream_spec.rb` — Replace batch behavior tests with rejection tests

---

### 6. `broadcast_message` Violates No-Broadcast Rule

**Severity:** HIGH | **Spec Level:** MUST | **Status: FIXED**

#### Spec Requirement

> The server **MUST** send each of its JSON-RPC messages on only one of the connected streams; that is, it **MUST NOT** broadcast the same message across multiple streams.

#### Resolution

**Fixed on 2026-04-09.** Implementation:

- Removed `broadcast_message` from `BaseSessionManager` entirely
- Removed `broadcast_notification` from `HttpStream` entirely
- Updated `Server::Capabilities` (`notify_prompts_list_changed` and `notify_roots_list_changed`) to use `send_notification` directly, which sends to a single session only
- Callers who need multi-session notification can iterate sessions explicitly with `send_notification_to_session`, making the per-stream constraint visible at the call site
- 3 tests updated in `server_spec.rb`, existing broadcast tests replaced with absence guards in `session_manager_spec.rb` and `http_stream_spec.rb`

#### Files Changed

- `lib/vector_mcp/transport/base_session_manager.rb` — Removed `broadcast_message`
- `lib/vector_mcp/transport/http_stream.rb` — Removed `broadcast_notification`
- `lib/vector_mcp/server/capabilities.rb` — Removed `broadcast_notification` branch from both notification methods

---

### 7. POST Accept Header Validation Too Lenient

**Severity:** MEDIUM | **Spec Level:** MUST (client requirement) | **Status: FIXED**

#### Spec Requirement

> The client **MUST** include an `Accept` header, listing both `application/json` and `text/event-stream` as supported content types.

#### Resolution

**Fixed on 2026-04-09.** `valid_post_accept?` now requires both `application/json` AND `text/event-stream` when an Accept header is present. `*/*` and missing/empty Accept headers are still accepted for backwards compatibility with non-browser clients.

#### Files Changed

- `lib/vector_mcp/transport/http_stream.rb` — Tightened `valid_post_accept?` from OR to AND

---

### 8. Event IDs Lack Stream Origin Information

**Severity:** MEDIUM | **Spec Level:** SHOULD + MUST | **Status: FIXED**

#### Spec Requirement

> Event IDs **SHOULD** encode sufficient information to identify the originating stream, enabling the server to correlate a `Last-Event-ID` to the correct stream.

> The server **MUST NOT** replay messages that would have been delivered on a different stream.

#### Resolution

**Fixed on 2026-04-09.** Implementation:

- Added `stream_id` field to `Event` struct in `EventStore`
- `store_event` accepts optional `stream_id:` keyword, passed through from `StreamHandler`
- `get_events_after` accepts optional `stream_id:` for filtering
- Each `StreamingConnection` generates a unique `stream_id` (`{session_id}-{origin}-{random}`)
- Events are stored with their originating `stream_id` for traceability
- **Critical design choice:** `replay_events` filters by `session_id` only (not `stream_id`) because resumability must work across reconnections where the `stream_id` changes. The `stream_id` is stored for auditing and future multi-stream support.

#### Files Changed

- `lib/vector_mcp/transport/http_stream/event_store.rb` — Added `stream_id` to Event struct, `store_event`, and `get_events_after`
- `lib/vector_mcp/transport/http_stream/stream_handler.rb` — Pass `stream_id` when storing events and heartbeats

---

### 9. No Distinction Between POST SSE and GET SSE Streams

**Severity:** MEDIUM | **Spec Level:** MUST | **Status: FIXED**

#### Spec Requirement

On GET streams:
> The server **MUST NOT** send a JSON-RPC response on the stream **unless** resuming a stream associated with a previous client request.

POST SSE streams may include the response plus interim requests and notifications.

#### Resolution

**Fixed on 2026-04-09.** Implementation:

- Added `origin` (`:get` or `:post`) and `stream_id` fields to `StreamingConnection` struct
- Added `from_get?` convenience method to `StreamingConnection`
- `send_message_to_session` checks `connection.from_get?` and `json_rpc_response?(message)` — blocks responses (both `result` and `error` keyed, string or symbol) on GET streams
- Added `json_rpc_response?` private helper that detects responses by presence of `result`/`error` keys without `method` key (handles both string and symbol keys)
- Notifications and server-initiated requests are still allowed on GET streams

#### Files Changed

- `lib/vector_mcp/transport/http_stream/stream_handler.rb` — Added `origin`, `stream_id`, `from_get?` to struct; added `json_rpc_response?` helper; gated `send_message_to_session`

---

## Potential Issues

### 10. Protocol Version Hardcoded to `2024-11-05`

**Severity:** MEDIUM | **Status: FIXED**

#### Resolution

**Fixed as part of Finding #1.** `PROTOCOL_VERSION` updated to `"2025-03-26"` and `SUPPORTED_PROTOCOL_VERSIONS = %w[2025-03-26 2024-11-05]` added. The server now advertises a current protocol version and validates the `MCP-Protocol-Version` header against the supported list.

---

### 11. Non-Standard SSE Events and JSON-RPC Methods

**Severity:** LOW | **Status: FIXED**

#### Resolution

**Fixed on 2026-04-09.** The `connection/established` event was previously replaced with a spec-compliant priming event (Finding #3). The remaining non-standard heartbeat event has now been fixed:

- Heartbeats now use SSE comments (`": heartbeat\n\n"`) instead of JSON-RPC notification objects
- Heartbeat events are no longer stored in the event store (SSE comments are not replayable, which is correct — they are keep-alive signals only)
- The `stream_id` parameter to `keep_alive_loop` is now unused (prefixed with `_`)

#### Files Changed

- `lib/vector_mcp/transport/http_stream/stream_handler.rb` — Replaced JSON-RPC heartbeat with SSE comment

---

### 12. POST SSE Response Is Non-Streaming

**Severity:** LOW | **Spec Level:** MAY

#### Spec Requirement

> The server **MAY** send JSON-RPC requests and notifications before sending the JSON-RPC response.

#### Current Behavior

`sse_rpc_response` (`lib/vector_mcp/transport/http_stream.rb:613-628`) creates a single SSE event and returns it immediately as the entire response body:

```ruby
[200, response_headers, [sse_event]]
```

This is a "short SSE" — one event, then the stream ends.

#### Impact

The server cannot send progress updates, server-initiated requests (like sampling), or other interim messages during long-running operations on the POST SSE stream. This limits functionality but doesn't violate a MUST requirement.

#### Suggested Fix

For long-running operations, create a long-lived SSE stream (similar to the GET handler) that emits interim events before the final response. This would require refactoring `handle_single_request` to return a streaming Rack body.

---

### 13. Origin Validation Error Response Format

**Severity:** LOW | **Spec Level:** MAY | **Status: FIXED**

#### Spec Requirement

> The HTTP response body **MAY** comprise a JSON-RPC error response that has no `id`.

#### Resolution

**Fixed on 2026-04-09.** `forbidden_response` now returns a JSON-RPC error object with `application/json` content type and error code `-32600` instead of plain text.

#### Files Changed

- `lib/vector_mcp/transport/http_stream.rb` — Updated `forbidden_response` to return JSON-RPC error

---

## Compliant Implementations

The following areas correctly implement the specification:

| Requirement | Status | Notes |
|-------------|--------|-------|
| Session ID in `InitializeResult` response | **Pass** | `Mcp-Session-Id` header included via `build_rpc_response` |
| Session ID format | **Pass** | `SecureRandom.uuid` -- globally unique, cryptographically secure, visible ASCII |
| Session validation on POST | **Pass** | Known ID returns session; unknown ID returns 404; no ID + init creates session; no ID + other returns 400 |
| Session termination via DELETE | **Pass** | Returns 204 on success, 404 if not found |
| Origin header validation | **Pass** | Validates against allowed list, returns 403 for invalid, permits absent Origin (non-browser) |
| Default localhost binding | **Pass** | `DEFAULT_HOST = "localhost"` |
| Event storage and replay | **Pass** | Events stored with unique IDs, stream_id, and replayed via `Last-Event-ID`; circular buffer with configurable retention. Session-scoped replay preserves resumability across reconnections. |
| Outgoing response handling | **Pass** | Client responses to server-initiated requests correctly detected and return 202 |
| GET Accept header validation | **Pass** | Requires `text/event-stream` or `*/*` |
| GET returns SSE stream | **Pass** | Returns `text/event-stream` content type with streaming body |
| Session expiry cleanup | **Pass** | Automatic cleanup via `Concurrent::TimerTask` every 60 seconds |
| MCP-Protocol-Version header | **Pass** | Validated on POST (except initialize), GET, and DELETE. Unsupported versions return 400. Missing header assumes `2025-03-26`. |
| Notification 202 response | **Pass** | Notifications (method + no id) return 202 Accepted with empty body |
| SSE priming event | **Pass** | Priming event (event ID + empty data) sent before all SSE streams (GET and POST) |
| SSE retry field | **Pass** | `retry: 5000` sent before intentional disconnections in `keep_alive_loop` |
| Protocol version negotiation | **Pass** | Server advertises `2025-03-26`, supports `2024-11-05` for backwards compatibility |

---

## Priority Matrix

### Immediate (MUST violations)

| # | Fix | Effort | Status |
|---|-----|--------|--------|
| 2 | Return 202 for notifications in `handle_single_request` | Small | **DONE** |
| 1 | Add `MCP-Protocol-Version` header validation | Medium | **DONE** |
| 6 | Remove `broadcast_message` / `broadcast_notification` | Medium | **DONE** |
| 5 | Reject batch requests | Small | **DONE** |

### Short-term (SHOULD violations and MUST-adjacent)

| # | Fix | Effort | Status |
|---|-----|--------|--------|
| 9 | Track stream origin (POST vs GET) in `StreamingConnection` | Medium | **DONE** |
| 8 | Add stream ID to events and filter replay by stream | Medium | **DONE** |
| 3 | Add SSE priming event with empty data field | Small | **DONE** |
| 4 | Add SSE `retry` field support | Small | **DONE** |
| 7 | Tighten POST Accept validation | Small | **DONE** |

### Later (low severity, nice-to-have)

| # | Fix | Effort | Status |
|---|-----|--------|--------|
| 10 | Update `PROTOCOL_VERSION` constant | Small | **DONE** |
| 11 | Replace custom SSE events with spec-compliant patterns | Medium | **DONE** |
| 12 | Support long-lived POST SSE streams | Large | Open |
| 13 | Return JSON-RPC error on 403 | Small | **DONE** |
