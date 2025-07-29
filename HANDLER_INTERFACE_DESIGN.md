# Handler Interface Design for Request Context

## Overview

This document outlines the design for updating the handler interface to use the new public session request context API, replacing the fragile `instance_variable_get` pattern.

## Current Problem

The `extract_request_from_session` method in `lib/vector_mcp/handlers/core.rb` uses:

```ruby
def self.extract_request_from_session(session)
  {
    headers: session.instance_variable_get(:@request_headers) || {},
    params: session.instance_variable_get(:@request_params) || {},
    session_id: session.respond_to?(:id) ? session.id : "test-session"
  }
end
```

This creates tight coupling and fragile dependencies on session internals.

## New Handler Interface Design

### 1. Updated Method Signature

```ruby
def self.extract_request_from_session(session)
  {
    headers: session.request_context.headers,
    params: session.request_context.params,
    session_id: session.id
  }
end
```

### 2. Enhanced Security Context Extraction

```ruby
def self.extract_security_context_from_session(session)
  context = session.request_context
  
  {
    headers: context.headers,
    params: context.params,
    method: context.method,
    path: context.path,
    session_id: session.id,
    transport_type: context.metadata("transport_type"),
    remote_addr: context.metadata("remote_addr"),
    user_agent: context.metadata("user_agent")
  }
end
```

### 3. Convenience Methods for Common Operations

```ruby
def self.extract_auth_headers_from_session(session)
  context = session.request_context
  
  {
    authorization: context.header("Authorization"),
    api_key: context.header("X-API-Key"),
    content_type: context.header("Content-Type")
  }
end

def self.extract_auth_params_from_session(session)
  context = session.request_context
  
  {
    api_key: context.param("api_key"),
    token: context.param("token")
  }
end
```

## Migration Strategy

### Phase 1: Backward Compatible Implementation

```ruby
def self.extract_request_from_session(session)
  # New interface (preferred)
  if session.respond_to?(:request_context) && session.request_context
    {
      headers: session.request_context.headers,
      params: session.request_context.params,
      session_id: session.id
    }
  else
    # Legacy fallback with deprecation warning
    VectorMCP.logger_for("handlers").warn(
      "Using deprecated instance_variable_get for session context. " \
      "Transport should populate request_context."
    )
    
    {
      headers: session.instance_variable_get(:@request_headers) || {},
      params: session.instance_variable_get(:@request_params) || {},
      session_id: session.respond_to?(:id) ? session.id : "test-session"
    }
  end
end
```

### Phase 2: Pure New Implementation

```ruby
def self.extract_request_from_session(session)
  raise ArgumentError, "Session must have request_context" unless session.respond_to?(:request_context)
  
  {
    headers: session.request_context.headers,
    params: session.request_context.params,
    session_id: session.id
  }
end
```

## Security Handler Integration

### Authentication Flow

```ruby
def self.authenticate_session(session)
  security_context = extract_security_context_from_session(session)
  
  # Use security middleware with proper context
  result = session.server.security_middleware.process_request(
    security_context,
    action: :authenticate,
    resource: nil
  )
  
  result
end
```

### Authorization Flow

```ruby
def self.authorize_session_for_resource(session, resource, action = :access)
  security_context = extract_security_context_from_session(session)
  
  result = session.server.security_middleware.process_request(
    security_context,
    action: action,
    resource: resource
  )
  
  result
end
```

## Error Handling

### Missing Context Handling

```ruby
def self.extract_request_from_session(session)
  unless session.respond_to?(:request_context)
    raise VectorMCP::InternalError, 
          "Session does not support request context. Transport layer must be updated."
  end
  
  context = session.request_context
  if context.nil?
    raise VectorMCP::InternalError,
          "Session request context is nil. Transport layer must populate context."
  end
  
  {
    headers: context.headers,
    params: context.params,
    session_id: session.id
  }
end
```

### Context Validation

```ruby
def self.validate_session_context(session)
  context = session.request_context
  
  errors = []
  errors << "Missing headers" unless context.headers.is_a?(Hash)
  errors << "Missing params" unless context.params.is_a?(Hash)
  errors << "Missing transport metadata" unless context.transport_metadata.is_a?(Hash)
  
  unless errors.empty?
    raise VectorMCP::InternalError, 
          "Invalid session context: #{errors.join(', ')}"
  end
  
  true
end
```

## Testing Interface

### Mock Session for Tests

```ruby
def self.create_test_session_with_context(server, **context_attrs)
  context = VectorMCP::RequestContext.new(**context_attrs)
  VectorMCP::Session.new(server, nil, id: "test-session", request_context: context)
end
```

### Test Context Builder

```ruby
def self.build_test_context(headers: {}, params: {}, method: "POST", path: "/test")
  VectorMCP::RequestContext.new(
    headers: headers,
    params: params,
    method: method,
    path: path,
    transport_metadata: { transport_type: "test" }
  )
end
```

## Performance Considerations

### Context Caching

```ruby
def self.extract_request_from_session_cached(session)
  # Cache the extracted context to avoid repeated access
  @_cached_context ||= {}
  @_cached_context[session.id] ||= begin
    context = session.request_context
    {
      headers: context.headers,
      params: context.params,
      session_id: session.id
    }
  end
end
```

### Lazy Evaluation

```ruby
def self.extract_security_context_lazy(session)
  # Only extract what's needed for security checks
  context = session.request_context
  
  OpenStruct.new(
    headers: -> { context.headers },
    params: -> { context.params },
    auth_header: -> { context.header("Authorization") },
    api_key: -> { context.param("api_key") },
    session_id: session.id
  )
end
```

## Benefits of New Interface

1. **Type Safety**: RequestContext provides structured access
2. **Decoupling**: No direct dependency on session internals
3. **Validation**: Context validation at creation time
4. **Extensibility**: Easy to add new context fields
5. **Documentation**: Self-documenting interface
6. **Testing**: Clear interface for mocking

## Implementation Checklist

- [ ] Update `extract_request_from_session` method
- [ ] Add backward compatibility layer
- [ ] Implement security context extraction
- [ ] Add error handling for missing context
- [ ] Update all handler methods to use new interface
- [ ] Add context validation
- [ ] Update tests to use new interface
- [ ] Add performance optimizations
- [ ] Document new interface usage