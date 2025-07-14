# Transport Layer Context Population Contract

## Overview

This document defines the formal contract for transport layers to populate request context data in VectorMCP sessions. This replaces the fragile coupling pattern where handler logic directly accessed session internal variables.

## Interface Requirements

### 1. Session Creation with Context

All transport layers MUST create sessions with proper request context using one of these patterns:

#### Option A: Initialize with Context (Recommended)
```ruby
# Create session with context during initialization
session = VectorMCP::Session.new(
  server, 
  transport, 
  id: session_id,
  request_context: context_data
)
```

#### Option B: Set Context After Creation
```ruby
# Create session and set context separately
session = VectorMCP::Session.new(server, transport, id: session_id)
session.set_request_context(context_data)
```

### 2. Context Data Structure

Context data can be provided as:

#### RequestContext Object (Preferred)
```ruby
context = VectorMCP::RequestContext.new(
  headers: extracted_headers,
  params: extracted_params,
  method: request_method,
  path: request_path,
  transport_metadata: transport_specific_data
)
```

#### Hash Format (Alternative)
```ruby
context_data = {
  headers: extracted_headers,
  params: extracted_params,
  method: request_method,
  path: request_path,
  transport_metadata: transport_specific_data
}
```

### 3. Required Context Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `headers` | Hash | Yes | HTTP headers or equivalent transport headers |
| `params` | Hash | Yes | Query parameters or equivalent transport parameters |
| `method` | String | No | HTTP method or transport-specific method identifier |
| `path` | String | No | Request path or transport-specific path |
| `transport_metadata` | Hash | No | Transport-specific metadata |

## Transport-Specific Implementation Guidelines

### HTTP-Based Transports (SSE, HTTP Stream)

For HTTP-based transports, use the convenience method:

```ruby
def create_session_with_context(rack_env, session_id)
  context = VectorMCP::RequestContext.from_rack_env(rack_env, transport_type)
  VectorMCP::Session.new(@server, self, id: session_id, request_context: context)
end
```

**Required Implementation:**
- Extract headers using `VectorMCP::Util.extract_headers_from_rack_env`
- Extract params using `VectorMCP::Util.extract_params_from_rack_env`
- Set method from `rack_env["REQUEST_METHOD"]`
- Set path from `rack_env["PATH_INFO"]`
- Include transport-specific metadata

### Non-HTTP Transports (Stdio)

For non-HTTP transports, use the minimal context:

```ruby
def create_session_with_context
  context = VectorMCP::RequestContext.minimal("stdio")
  VectorMCP::Session.new(@server, self, request_context: context)
end
```

**Required Implementation:**
- Use empty headers and params
- Set method to transport name (e.g., "STDIO")
- Set path to "/" or transport-appropriate default
- Include transport type in metadata

## Security Considerations

### Authentication Context
Transports MUST populate authentication-related headers:
- `Authorization` header from HTTP requests
- `X-API-Key` header from HTTP requests
- Custom authentication headers as appropriate

### Security Metadata
Include security-relevant information in transport_metadata:
- `remote_addr` - Client IP address
- `user_agent` - Client user agent
- `content_type` - Request content type
- `transport_type` - Transport identifier

## Migration Strategy

### Phase 1: Dual Support (Current)
- Support both old (`instance_variable_get`) and new (public interface) patterns
- Transport layers can gradually adopt new pattern
- Handler logic uses new interface with fallback to old pattern

### Phase 2: New Pattern Only (Future)
- Remove `instance_variable_get` fallback from handler logic
- All transports must use new pattern
- Deprecation warnings for old pattern usage

## Testing Requirements

### Unit Tests
Each transport layer MUST include tests for:
- Session creation with proper context
- Context population with various request formats
- Security header extraction
- Transport-specific metadata inclusion

### Integration Tests
Each transport layer MUST include tests for:
- Authentication flow with context
- Authorization checks using context
- Handler access to context data
- Error handling with malformed context

## Implementation Examples

### HTTP Stream Transport
```ruby
class VectorMCP::Transport::HttpStream
  def handle_request(rack_env)
    session_id = extract_session_id(rack_env)
    session = create_session_with_context(rack_env, session_id)
    # ... handle request
  end

  private

  def create_session_with_context(rack_env, session_id)
    context = VectorMCP::RequestContext.from_rack_env(rack_env, "http_stream")
    VectorMCP::Session.new(@server, self, id: session_id, request_context: context)
  end
end
```

### SSE Transport
```ruby
class VectorMCP::Transport::SSE
  def handle_message(rack_env, session_id)
    session = @session_manager.get_session(session_id)
    if session.nil?
      context = VectorMCP::RequestContext.from_rack_env(rack_env, "sse")
      session = VectorMCP::Session.new(@server, self, id: session_id, request_context: context)
      @session_manager.add_session(session)
    end
    # ... handle message
  end
end
```

### Stdio Transport
```ruby
class VectorMCP::Transport::Stdio
  def run
    context = VectorMCP::RequestContext.minimal("stdio")
    session = VectorMCP::Session.new(@server, self, request_context: context)
    # ... handle stdio communication
  end
end
```

## Benefits of This Contract

1. **Decoupling**: Handler logic no longer depends on session internals
2. **Type Safety**: Structured context with validation
3. **Consistency**: Uniform interface across all transport types
4. **Extensibility**: Easy to add new context fields
5. **Testability**: Clear interface for mocking and testing
6. **Documentation**: Self-documenting contract with clear expectations

## Compliance Checklist

- [ ] Transport creates sessions with request context
- [ ] Context includes required fields (headers, params)
- [ ] Security headers are properly extracted
- [ ] Transport metadata is included
- [ ] Unit tests cover context population
- [ ] Integration tests verify handler access
- [ ] Error handling for malformed context
- [ ] Documentation updated with transport-specific examples