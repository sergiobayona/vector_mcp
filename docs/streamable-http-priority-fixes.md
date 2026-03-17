# Streamable HTTP Transport — Priority Fixes

Audit of `VectorMCP::Transport::HttpStream` against the MCP Streamable HTTP specification (2025-03-26 / 2024-11-05).

Each fix below is ordered by severity. For every issue we document: the spec requirement, what the code does today, the files and lines involved, and a concrete implementation approach.

---

## Table of Contents

1. [Fix 1: Session ID Validation on POST — Reject Unknown/Expired Sessions](#fix-1-session-id-validation-on-post)
2. [Fix 2: SSE Response Mode on POST — Dual Content-Type Support](#fix-2-sse-response-mode-on-post)
3. [Fix 3: Batch JSON-RPC Request Dispatch](#fix-3-batch-json-rpc-request-dispatch)
4. [Fix 4: Per-Session Event Store — Prevent Cross-Session Event Leakage](#fix-4-per-session-event-store)
5. [Fix 5: Accept Header Validation on POST](#fix-5-accept-header-validation-on-post)
6. [Fix 6: Return 409 Conflict for Evicted Event IDs](#fix-6-return-409-conflict-for-evicted-event-ids)
7. [Fix 7: Update Protocol Version to 2025-03-26](#fix-7-update-protocol-version)

---

## Fix 1: Session ID Validation on POST

**Severity:** High
**Category:** Session Management / Security

### Spec Requirement

> If an unknown or expired `Mcp-Session-Id` is received, the server MUST respond with HTTP `404 Not Found`. The client MUST then start a new session by sending a fresh `initialize` request without a session ID header.

### Current Behavior

`SessionManager#get_or_create_session` in `lib/vector_mcp/transport/http_stream/session_manager.rb:79-96` silently creates a brand-new session when the provided session ID is not found:

```ruby
def get_or_create_session(session_id = nil, rack_env = nil)
  if session_id
    session = get_session(session_id)
    if session
      # ... update and return existing session
      return session
    end

    # If session_id was provided but not found, create with that ID
    return create_session(session_id, rack_env)  # <-- PROBLEM
  end

  create_session(nil, rack_env)
end
```

This is called from `handle_post_request` in `lib/vector_mcp/transport/http_stream.rb:333-334`:

```ruby
session_id = extract_session_id(env)
session = @session_manager.get_or_create_session(session_id, env)
```

### Problems

1. **Session fixation** — A client can force an arbitrary session ID. The server accepts it and creates a session with that exact ID, bypassing `SecureRandom.uuid` generation.
2. **Silent session resurrection** — Expired sessions don't 404; they silently come back with a fresh state. The client never learns its session expired.
3. **No initialization enforcement** — A stale client keeps operating on what it thinks is its old session, but the server has a brand-new uninitialized context. Subsequent method calls will hit `InitializationError` from `validate_session_initialization` rather than the correct `404` transport error.

### Proposed Fix

Split the POST handler's session logic into two distinct paths:

**In `lib/vector_mcp/transport/http_stream.rb`, modify `handle_post_request`:**

```ruby
def handle_post_request(env)
  session_id = extract_session_id(env)
  request_body = read_request_body(env)
  message = parse_json_message(request_body)

  session = resolve_session_for_post(session_id, message, env)
  return session if session.is_a?(Array) # Rack error response

  # ... rest of handler unchanged
end
```

**Add a new method `resolve_session_for_post`:**

```ruby
def resolve_session_for_post(session_id, message, env)
  is_initialize = message.is_a?(Hash) && message["method"] == "initialize"

  if session_id
    # Client provided a session ID — it MUST exist
    session = @session_manager.get_session(session_id)
    return not_found_response("Unknown or expired session") unless session

    # Update request context on the existing session
    update_session_context(session, env)
    session
  elsif is_initialize
    # No session ID + initialize request = create new session
    @session_manager.create_session(nil, env)
  else
    # No session ID + non-initialize request = error
    bad_request_response("Missing Mcp-Session-Id header")
  end
end
```

**In `lib/vector_mcp/transport/http_stream/session_manager.rb`:**

Remove the auto-create-with-client-ID branch from `get_or_create_session`, or deprecate the method in favor of explicit `get_session` / `create_session` calls from the transport. Ensure `create_session` always generates its own ID via `SecureRandom.uuid` when the caller doesn't provide one:

```ruby
def create_session(session_id = nil, rack_env = nil)
  session_id ||= generate_session_id  # Always server-generated
  # ... rest unchanged
end
```

### Test Cases

- POST with valid `Mcp-Session-Id` returns `200` with result.
- POST with unknown `Mcp-Session-Id` returns `404 Not Found`.
- POST with expired `Mcp-Session-Id` returns `404 Not Found`.
- POST `initialize` without `Mcp-Session-Id` creates a new session and returns the session ID in response headers.
- POST non-initialize without `Mcp-Session-Id` returns `400 Bad Request`.
- Verify the returned `Mcp-Session-Id` is server-generated (UUID format), not client-supplied.

---

## Fix 2: SSE Response Mode on POST

**Severity:** High
**Category:** Response Modes / Streaming

### Spec Requirement

> When a server receives a JSON-RPC request via HTTP POST, it can respond in one of two ways:
> 1. A single JSON-RPC response in the HTTP response body with `Content-Type: application/json`.
> 2. An SSE stream (`Content-Type: text/event-stream`) that can carry one or more JSON-RPC messages (progress notifications, partial results, and the final response) before closing.
>
> The server SHOULD use the SSE stream for responses that may take significant time or when it needs to send notifications alongside the response.

### Current Behavior

Every POST response goes through `json_rpc_response` in `lib/vector_mcp/transport/http_stream.rb:448-463`, which unconditionally sets `Content-Type: application/json`:

```ruby
def json_rpc_response(result, request_id, headers = {})
  response = @hash_pool.pop || {}
  response.clear
  response[:jsonrpc] = "2.0"
  response[:id] = request_id
  response[:result] = result

  response_headers = { "Content-Type" => "application/json" }.merge(headers)
  json_result = response.to_json
  @hash_pool << response if @hash_pool.size < 20

  [200, response_headers, [json_result]]
end
```

There is no code path that returns `text/event-stream` from a POST. Tool calls that take time, emit progress, or return streaming data have no way to deliver incremental results.

### Proposed Fix

Add an SSE response mode alongside the existing JSON mode. The server decides which mode to use based on:

1. Whether the client's `Accept` header includes `text/event-stream`.
2. Whether the handler signals it needs streaming (e.g., a long-running tool, or the server wants to send notifications alongside the response).

**Step 1: Add response mode detection to `handle_post_request`:**

```ruby
def handle_post_request(env)
  # ... session resolution, body parsing ...

  accepts_sse = client_accepts_sse?(env)

  result = @server.handle_message(message, session.context, session.id)

  headers = { "Mcp-Session-Id" => session.id }

  if accepts_sse && should_stream_response?(message, result)
    sse_rpc_response(result, message["id"], headers)
  else
    json_rpc_response(result, message["id"], headers)
  end
end
```

**Step 2: Add helpers:**

```ruby
def client_accepts_sse?(env)
  accept = env["HTTP_ACCEPT"] || ""
  accept.include?("text/event-stream")
end

def should_stream_response?(message, result)
  # Start simple: stream if the result is an Enumerator or if the method
  # is known to be long-running. Expand criteria as needed.
  result.is_a?(Enumerator) || result.is_a?(Proc)
end
```

**Step 3: Implement `sse_rpc_response`:**

```ruby
def sse_rpc_response(result, request_id, headers = {})
  response_headers = {
    "Content-Type" => "text/event-stream",
    "Cache-Control" => "no-cache",
    "Connection" => "keep-alive",
    "X-Accel-Buffering" => "no"
  }.merge(headers)

  body = Enumerator.new do |yielder|
    # If result is enumerable (streaming), yield each chunk as an SSE event
    if result.respond_to?(:each)
      result.each do |chunk|
        event_data = { jsonrpc: "2.0", method: "notifications/progress", params: chunk }.to_json
        event_id = @event_store.store_event(event_data, "message")
        yielder << format_sse_event(event_data, "message", event_id)
      end
    end

    # Always send the final JSON-RPC response as the last event
    final = { jsonrpc: "2.0", id: request_id, result: result }.to_json
    event_id = @event_store.store_event(final, "message")
    yielder << format_sse_event(final, "message", event_id)
  end

  [200, response_headers, body]
end

def format_sse_event(data, type, event_id)
  lines = []
  lines << "id: #{event_id}"
  lines << "event: #{type}" if type
  lines << "data: #{data}"
  lines << ""
  "#{lines.join("\n")}\n"
end
```

**Step 4: Extend tool handlers to opt into streaming.**

Consider adding a `:streaming` flag to tool definitions so tools can signal they want SSE responses:

```ruby
server.register_tool(
  name: "long_analysis",
  description: "Runs a lengthy analysis with progress updates",
  input_schema: { ... },
  streaming: true
) do |args, session|
  Enumerator.new do |yielder|
    yielder << { progress: 0.25, status: "Loading data..." }
    yielder << { progress: 0.75, status: "Processing..." }
    yielder << { type: "text", text: "Analysis complete: ..." }
  end
end
```

### Scope

This is the largest fix. A minimal viable approach:

1. For Phase 1, only support SSE responses for tools that explicitly return an `Enumerator`.
2. For Phase 2, add server-initiated notifications mid-request (progress callbacks).
3. For Phase 3, support multiplexed responses (batched requests returning individual results as SSE events).

### Test Cases

- POST with `Accept: application/json` always returns JSON.
- POST with `Accept: text/event-stream, application/json` returns SSE when the handler streams.
- SSE response stream contains intermediate events and a final JSON-RPC response.
- SSE events in the response have proper `id:`, `event:`, and `data:` fields.
- Non-streaming tools still return plain JSON even if client accepts SSE.

---

## Fix 3: Batch JSON-RPC Request Dispatch

**Severity:** Medium
**Category:** Protocol Compliance

### Spec Requirement

> The JSON-RPC 2.0 specification allows clients to send a batch of requests as a JSON array. The server MUST process each request in the batch and return an array of responses.

### Current Behavior

`parse_json_message` in `lib/vector_mcp/transport/http_stream.rb:410-425` correctly accepts both `{...}` objects and `[...]` arrays:

```ruby
unless (body_stripped.start_with?("{") && body_stripped.end_with?("}")) ||
       (body_stripped.start_with?("[") && body_stripped.end_with?("]"))
  raise JSON::ParserError, "Invalid JSON structure"
end

JSON.parse(body_stripped)
```

But `handle_post_request` at line 346 passes the result directly to `@server.handle_message(message, ...)`, which expects a `Hash` and accesses `message["id"]`, `message["method"]`. If an `Array` is passed, these calls return `nil`, and the message is treated as invalid.

### Proposed Fix

**In `lib/vector_mcp/transport/http_stream.rb`, modify `handle_post_request`:**

```ruby
def handle_post_request(env)
  session_id = extract_session_id(env)
  session = resolve_session_for_post(session_id, message, env)
  return session if session.is_a?(Array)

  request_body = read_request_body(env)
  parsed = parse_json_message(request_body)

  if parsed.is_a?(Array)
    handle_batch_request(parsed, session)
  else
    handle_single_request(parsed, session)
  end
rescue VectorMCP::ProtocolError => e
  json_error_response(e.request_id, e.code, e.message, e.details)
rescue JSON::ParserError => e
  json_error_response(nil, -32_700, "Parse error", { details: e.message })
end
```

**Add `handle_batch_request`:**

```ruby
def handle_batch_request(messages, session)
  return json_error_response(nil, -32_600, "Invalid Request", { details: "Empty batch" }) if messages.empty?

  responses = messages.filter_map do |message|
    next unless message.is_a?(Hash)

    handle_single_message_in_batch(message, session)
  end

  headers = { "Content-Type" => "application/json", "Mcp-Session-Id" => session.id }
  [200, headers, [responses.to_json]]
end

def handle_single_message_in_batch(message, session)
  # Skip outgoing responses
  if outgoing_response?(message)
    handle_outgoing_response(message)
    return nil
  end

  result = @server.handle_message(message, session.context, session.id)

  # Notifications return nil — no response object
  return nil if result.nil? && message["id"].nil?

  { jsonrpc: "2.0", id: message["id"], result: result }
rescue VectorMCP::ProtocolError => e
  { jsonrpc: "2.0", id: e.request_id, error: { code: e.code, message: e.message, data: e.details } }
rescue StandardError => e
  { jsonrpc: "2.0", id: message["id"], error: { code: -32_603, message: "Internal error", data: { details: e.message } } }
end
```

**Extract `handle_single_request` from the current `handle_post_request` body** for the non-batch path, keeping the same behavior.

### Edge Cases

- An empty array `[]` should return a JSON-RPC error (invalid request).
- A batch containing only notifications should return an empty HTTP response (no body), or a `204 No Content`.
- Errors in individual batch items should not abort the rest of the batch. Each item gets its own response or error object.
- Batch containing a mix of requests and notifications: only requests produce response objects.

### Test Cases

- Single object POST works as before.
- Array of two requests returns array of two responses.
- Array with one request and one notification returns array of one response.
- Empty array returns error.
- Malformed items within a batch are individually error-reported.

---

## Fix 4: Per-Session Event Store

**Severity:** Medium
**Category:** Session Isolation / Information Leakage

### Current Behavior

A single `EventStore` instance is created per transport at `lib/vector_mcp/transport/http_stream.rb:701`:

```ruby
@event_store = HttpStream::EventStore.new(@event_retention)
```

All sessions share this store. When `StreamHandler#send_message_to_session` stores an event at `lib/vector_mcp/transport/http_stream/stream_handler.rb:71`:

```ruby
event_id = @transport.event_store.store_event(event_data, "message")
```

...the event enters the global pool. When a client reconnects with `Last-Event-ID`, `replay_events` at `lib/vector_mcp/transport/http_stream/stream_handler.rb:190-198` replays **all** events after that ID:

```ruby
def replay_events(yielder, last_event_id)
  missed_events = @transport.event_store.get_events_after(last_event_id)
  missed_events.each do |event|
    yielder << event.to_sse_format
  end
end
```

This means Session A's events can be replayed to Session B if B reconnects with a `Last-Event-ID` that predates Session A's events.

### Proposed Fix

**Option A: Per-session event stores (recommended)**

Move event store ownership from the transport to the session manager. Each session gets its own store.

In `lib/vector_mcp/transport/http_stream/session_manager.rb`, update the `Session` struct:

```ruby
Session = Struct.new(:id, :context, :created_at, :last_accessed_at, :metadata) do
  # ... existing methods ...

  def event_store
    metadata[:event_store]
  end
end
```

In `create_session`:

```ruby
metadata = {
  streaming_connection: nil,
  event_store: EventStore.new(@transport.event_store.max_events)
}
```

Update `StreamHandler#send_message_to_session` and `replay_events` to use `session.event_store` instead of `@transport.event_store`.

**Option B: Tag events with session ID and filter on replay**

If a shared store is preferred for simplicity, add a `session_id` field to `Event` and filter in `get_events_after`:

```ruby
Event = Struct.new(:id, :data, :type, :timestamp, :session_id) do
  # ...
end

def get_events_after(last_event_id, session_id: nil)
  # ... existing logic, then filter:
  events = @events[start_index..]
  events = events.select { |e| e.session_id == session_id } if session_id
  events
end
```

### Test Cases

- Session A stores events. Session B reconnects with `Last-Event-ID`. Session B receives only its own events.
- Session A's event IDs are not visible to Session B.
- Replay after session-scoped event store eviction returns empty (or 409 per Fix 6).

---

## Fix 5: Accept Header Validation on POST

**Severity:** Medium
**Category:** Protocol Compliance

### Spec Requirement

> Clients MUST include an `Accept` header in all HTTP requests, listing the content types they can handle. For POST requests, clients MUST include both `application/json` and `text/event-stream` in the `Accept` header.
>
> Servers SHOULD validate the `Accept` header and return `406 Not Acceptable` if the required content types are not present.

### Current Behavior

There is no `Accept` header validation anywhere in the HttpStream transport. The server ignores the header entirely.

### Proposed Fix

**In `lib/vector_mcp/transport/http_stream.rb`, add validation in `handle_post_request`:**

```ruby
def handle_post_request(env)
  return not_acceptable_response unless valid_accept_header?(env)

  # ... rest of handler
end
```

**Add helper methods:**

```ruby
def valid_accept_header?(env)
  accept = env["HTTP_ACCEPT"]

  # If no Accept header, be lenient (some clients/tools omit it)
  return true if accept.nil? || accept.strip.empty?

  # Must accept at least application/json
  # Wildcard */* also satisfies
  accept.include?("application/json") ||
    accept.include?("*/*")
end

def not_acceptable_response
  [406, { "Content-Type" => "text/plain" },
   ["Not Acceptable. POST requests must Accept application/json."]]
end
```

For the GET endpoint, also validate that the client accepts `text/event-stream`:

```ruby
def handle_get_request(env)
  accept = env["HTTP_ACCEPT"] || ""
  unless accept.include?("text/event-stream") || accept.include?("*/*") || accept.empty?
    return not_acceptable_response_sse
  end
  # ... rest of handler
end
```

### Strictness Level

The spec says SHOULD, not MUST, for server-side validation. A pragmatic approach:

- **Lenient mode (default):** Log a warning if `Accept` is missing or wrong, but process the request. This avoids breaking existing clients.
- **Strict mode (opt-in):** Return `406`. Enable via configuration: `HttpStream.new(server, strict_accept: true)`.

### Test Cases

- POST with `Accept: application/json, text/event-stream` succeeds.
- POST with `Accept: application/json` succeeds (sufficient for JSON responses).
- POST with `Accept: text/html` returns `406` (in strict mode).
- POST with no `Accept` header succeeds (lenient).
- GET with `Accept: text/event-stream` succeeds.

---

## Fix 6: Return 409 Conflict for Evicted Event IDs

**Severity:** Medium
**Category:** Resumable Streams

### Spec Requirement

> If the server receives a `Last-Event-ID` that it cannot fulfill (e.g., the events have been purged from storage), it SHOULD respond with HTTP `409 Conflict`, indicating the client must re-initialize.

### Current Behavior

`EventStore#get_events_after` in `lib/vector_mcp/transport/http_stream/event_store.rb:76-87` returns an empty array when the `Last-Event-ID` is not found:

```ruby
def get_events_after(last_event_id)
  return @events.to_a if last_event_id.nil?

  last_index = @event_index[last_event_id]
  return [] if last_index.nil?  # <-- Silent empty result

  start_index = last_index + 1
  return [] if start_index >= @events.length

  @events[start_index..]
end
```

`StreamHandler#handle_streaming_request` passes this through and starts an SSE stream with zero replayed events. The client has no way to know it missed events and should re-initialize.

### Proposed Fix

**Step 1: Add an `event_id_known?` check to `EventStore`:**

```ruby
# Returns :known, :evicted, or :unknown
def event_id_status(event_id)
  return :known if @event_index.key?(event_id)

  # If we have events and the ID format looks valid but isn't in the index,
  # it was likely evicted from the circular buffer
  return :evicted if @events.any? && plausible_event_id?(event_id)

  :unknown
end

private

def plausible_event_id?(event_id)
  # Event IDs follow the format: timestamp-sequence-hex
  event_id.match?(/\A\d+-\d+-[0-9a-f]+\z/)
end
```

**Step 2: Check in `StreamHandler#handle_streaming_request`:**

```ruby
def handle_streaming_request(env, session)
  last_event_id = extract_last_event_id(env)

  if last_event_id
    status = @transport.event_store.event_id_status(last_event_id)
    if status == :evicted
      logger.warn("Last-Event-ID #{last_event_id} has been evicted, returning 409")
      return [409, { "Content-Type" => "text/plain" }, ["Event ID no longer available. Re-initialize session."]]
    end
  end

  # ... continue with normal streaming
end
```

### Test Cases

- GET with `Last-Event-ID` that exists in store replays events normally.
- GET with `Last-Event-ID` that was evicted (buffer rolled past it) returns `409 Conflict`.
- GET without `Last-Event-ID` starts fresh stream.
- After receiving `409`, client sends new `initialize` POST and re-establishes session.

---

## Fix 7: Update Protocol Version

**Severity:** Medium
**Category:** Protocol Compliance

### Current Behavior

`lib/vector_mcp/server.rb:71` declares:

```ruby
PROTOCOL_VERSION = "2024-11-05"
```

The latest MCP specification version is `2025-03-26`.

### Proposed Fix

Update the constant after all transport fixes are applied:

```ruby
PROTOCOL_VERSION = "2025-03-26"
```

This should only be done once the Streamable HTTP transport fully complies with the 2025-03-26 spec. Bumping the version prematurely would be misleading to clients that negotiate capabilities based on the protocol version.

### Pre-Requisites

Before bumping to `2025-03-26`, at minimum:

- Fix 1 (session validation) is implemented.
- Fix 3 (batch support) is implemented.
- Fix 5 (Accept header) is at least lenient-mode implemented.

---

## Implementation Order

Recommended sequencing based on dependencies and impact:

| Order | Fix | Effort | Reason |
|-------|-----|--------|--------|
| 1 | Fix 1: Session ID validation | Small | Security-critical, self-contained change |
| 2 | Fix 5: Accept header validation | Small | Simple guard, no architectural changes |
| 3 | Fix 3: Batch dispatch | Medium | Protocol compliance, isolated to POST handler |
| 4 | Fix 4: Per-session event store | Medium | Data isolation, affects store + handler |
| 5 | Fix 6: 409 for evicted events | Small | Depends on Fix 4 for session-scoped stores |
| 6 | Fix 2: SSE response mode on POST | Large | Architectural change, new streaming path |
| 7 | Fix 7: Protocol version bump | Trivial | Only after core fixes land |

---

## Files Affected

| File | Fixes |
|------|-------|
| `lib/vector_mcp/transport/http_stream.rb` | 1, 2, 3, 5 |
| `lib/vector_mcp/transport/http_stream/session_manager.rb` | 1, 4 |
| `lib/vector_mcp/transport/http_stream/event_store.rb` | 4, 6 |
| `lib/vector_mcp/transport/http_stream/stream_handler.rb` | 2, 4, 6 |
| `lib/vector_mcp/server.rb` | 7 |
| `lib/vector_mcp/server/message_handling.rb` | 3 (if batch needs dispatch-level changes) |
