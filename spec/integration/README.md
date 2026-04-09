# Integration Tests

This directory contains integration tests that verify the end-to-end functionality of VectorMCP transports and servers.

## HTTP Stream Transport Integration Test

**File:** `http_stream_basic_integration_spec.rb`

This test verifies the reliability and functionality of the HTTP Stream transport implementation. It tests:

### Verified Functionality

1. **Server Health and Connectivity**
   - Health check endpoint responses
   - Proper HTTP headers
   - HTTP method validation (POST/GET/DELETE for `/mcp`)
   - 404 responses for unknown paths

2. **Session Management**
   - Session creation via `initialize` request
   - `Mcp-Session-Id` header handling
   - Unique session ID generation for multiple connections
   - Proper UUID format validation
   - Session termination via DELETE

3. **JSON-RPC Message Handling**
   - Malformed JSON error handling
   - Proper error code responses (-32700 for parse errors)
   - Session ID validation on POST requests

4. **Resumable Connections**
   - `Last-Event-ID` header support
   - Event storage and replay

5. **Concurrent Connections**
   - Multiple simultaneous connections
   - Session isolation between clients

6. **Transport Lifecycle**
   - Graceful server startup and shutdown
   - Resource cleanup

### Usage

Run the integration test with:

```bash
bundle exec rspec spec/integration/http_stream_basic_integration_spec.rb
```

This test complements the unit tests and provides confidence that the HTTP Stream transport works correctly in realistic scenarios with actual HTTP connections and concurrent clients.
