# Integration Tests

This directory contains integration tests that verify the end-to-end functionality of VectorMCP transports and servers.

## SSE Transport Integration Test

**File:** `sse_basic_integration_spec.rb`

This test verifies the reliability and functionality of the SSE (Server-Sent Events) transport implementation. It tests:

### ✅ Verified Functionality

1. **Server Health and Connectivity**
   - Health check endpoint responses
   - Proper SSE headers (Content-Type, Cache-Control, Connection)
   - HTTP method validation (GET for SSE, POST for messages)
   - 404 responses for unknown paths

2. **SSE Connection Establishment**
   - SSE endpoint event delivery with session information
   - Unique session ID generation for multiple connections
   - Proper UUID format validation

3. **Message Endpoint Validation**
   - Session ID parameter validation
   - Rejection of invalid session IDs
   - HTTP method enforcement

4. **JSON-RPC Message Handling**
   - Malformed JSON error handling
   - Proper error code responses (-32700 for parse errors)

5. **Concurrent Connections**
   - Multiple simultaneous SSE connections
   - Session isolation between clients

6. **Transport Lifecycle**
   - Graceful server startup and shutdown
   - Resource cleanup

### Test Coverage

The integration test achieves **82.66% code coverage** and validates:

- **HTTP server functionality** using Puma
- **SSE stream establishment** and event delivery
- **Session management** and isolation
- **Error handling** for various failure scenarios
- **Concurrent client support**
- **Resource cleanup** and graceful shutdown

### Performance Characteristics

The test demonstrates that the SSE transport can:
- Start up within 10 seconds
- Handle multiple concurrent connections
- Respond to requests within reasonable timeouts
- Clean up resources properly on shutdown

### Usage

Run the integration test with:

```bash
bundle exec rspec spec/integration/sse_basic_integration_spec.rb
```

This test complements the unit tests and provides confidence that the SSE transport works correctly in realistic scenarios with actual HTTP connections and concurrent clients.

## Stdio Transport Integration Test

**File:** `server_stdio_spec.rb`

Comprehensive integration test for the stdio transport, testing the complete MCP protocol flow including initialization, tool calls, resource access, and prompt handling.