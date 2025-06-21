# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

VectorMCP is a Ruby gem implementing the Model Context Protocol (MCP) server-side specification. It provides a framework for creating MCP servers that expose tools, resources, prompts, and roots to LLM clients.

## Essential Commands

### Development Setup

```bash
bin/setup          # Install dependencies and setup development environment
bin/console        # Interactive Ruby console with the gem loaded
```

### Testing and Quality

```bash
rake               # Run default task (tests + linting)
bundle exec spec          # Run RSpec test suite
bindle exec rspec ./spec/vector_mcp/examples_spec.rb # run a single test file
bundle exec rubocop       # Run RuboCop linting and style checks
```

### Documentation

```bash
rake yard          # Generate YARD documentation
rake doc           # Alias for yard (outputs to doc/ directory)
```

### Example Usage

```bash
ruby examples/simple_server.rb      # Basic MCP server demo
ruby examples/stdio_server.rb       # Stdio transport example
ruby examples/roots_demo.rb         # Filesystem roots demonstration
ruby examples/http_server.rb        # HTTP server with SSE transport example
```

## Architecture

### Core Components

- **VectorMCP::Server** (`lib/vector_mcp/server.rb`): Main server class handling MCP protocol
- **Transport Layer** (`lib/vector_mcp/transport/`): Communication protocols
  - `Stdio`: Standard input/output (stable)
  - `Sse`: Server-Sent Events over HTTP (stable)
- **Handlers** (`lib/vector_mcp/handlers/`): Request processing logic
- **Sampling** (`lib/vector_mcp/sampling/`): Server-initiated LLM requests with streaming support
- **Definitions** (`lib/vector_mcp/definitions.rb`): Tool, Resource, and Prompt definitions

### Key Features

- **Tools**: Custom functions that LLMs can invoke
- **Resources**: Data sources for LLM consumption
- **Prompts**: Structured prompt templates
- **Roots**: Filesystem boundaries for security and workspace context
- **Sampling**: LLM completion requests with streaming, tool calls, and image support

### Request Flow

**Stdio Transport:**
1. Client connects via stdin/stdout
2. JSON-RPC messages processed line-by-line
3. Handlers dispatch to registered tools/resources/prompts
4. Responses sent back via stdout

**SSE Transport:**
1. Client establishes SSE connection (`GET /sse`)
2. Server sends session info and message endpoint URL
3. Client sends JSON-RPC requests (`POST /message?session_id=<id>`)
4. Server processes requests and sends responses via SSE stream
5. Handlers dispatch to registered tools/resources/prompts
6. All responses formatted according to MCP specification

## Development Guidelines

### Code Structure

- Use `lib/vector_mcp/` for core functionality
- Place examples in `examples/` directory
- Tests go in `spec/` with matching directory structure
- Follow existing async patterns using the `async` gem

### Error Handling

Use VectorMCP-specific error classes:

- `VectorMCP::InvalidRequestError`
- `VectorMCP::MethodNotFoundError`
- `VectorMCP::InvalidParamsError`
- `VectorMCP::NotFoundError`
- `VectorMCP::InternalError`
- `VectorMCP::SamplingTimeoutError`
- `VectorMCP::SamplingError`

### Testing

- Run tests with `rake spec` before committing
- Use RSpec for behavior-driven testing
- Test coverage tracked with SimpleCov (coverage/ directory)
- Ensure rubocop passes with `rake rubocop`

### Dependencies

**Runtime**: async, async-container, async-http, async-io, base64, falcon
**Development**: rspec, rubocop, simplecov, yard, pry-byebug

### Version Management

Version defined in `lib/vector_mcp/version.rb` (currently 0.3.0)

## Security Strategy

Based on Windows MCP security recommendations and comprehensive codebase analysis (June 2025), VectorMCP requires significant security enhancements:

### Critical Vulnerabilities Identified

**HIGH RISK:**
- **No Authentication/Authorization** - Any client can connect and use tools (`lib/vector_mcp/transport/sse.rb:handle_sse_connection`)
- **Code Injection Risks** - Tools execute with full server privileges (`lib/vector_mcp/handlers/core.rb:62`)
- **Privilege Escalation** - No sandboxing or capability restrictions

**MEDIUM RISK:**
- **Session Management** - Weak session handling, no timeouts (`lib/vector_mcp/session.rb:25`)
- **Cross-Prompt Injection** - No content sanitization for LLM consumption (`lib/vector_mcp/util.rb:43-48`)
- **Resource Access Control** - No access policies on resources (`lib/vector_mcp/handlers/core.rb:91-98`)

### Security Implementation Plan

**Phase 1: Authentication & Authorization Framework**
```ruby
# Planned: API key authentication
class VectorMCP::Security::Authenticator
  def authenticate(request)
    api_key = request.headers['X-API-Key']
    raise UnauthorizedError unless valid_key?(api_key)
  end
end

# Planned: Tool-level permissions
server.register_tool(name: 'file_read', permissions: ['file:read']) do |args|
  # Tool implementation with capability checks
end
```

**Phase 2: Tool Execution Security**
```ruby
# Planned: Sandboxed tool execution
class VectorMCP::Security::ToolSandbox
  def execute(tool, args)
    container = create_container(tool.permissions)
    container.execute(tool.handler, args)
  end
end
```

**Phase 3: Content Security**
```ruby
# Planned: Cross-prompt injection prevention
class VectorMCP::Security::ContentFilter
  def sanitize_output(content)
    # Remove prompt injection patterns
    # Escape dangerous characters
    # Validate content safety
  end
end
```

### Windows-Inspired Security Controls

1. **Proxy-Mediated Communication** - Route through security proxy
2. **Tool Signing** - Require cryptographic signatures for tools
3. **Granular Permissions** - Per-tool capability declarations
4. **Runtime Isolation** - Container-based tool execution
5. **User Consent** - Explicit approval for sensitive operations

### Current Security Measures

**Implemented:**
- JSON Schema input validation (`lib/vector_mcp/handlers/core.rb:317-327`)
- Basic path traversal protection (`lib/vector_mcp/definitions.rb:255`)
- Structured error handling without stack trace leakage (`lib/vector_mcp/errors.rb`)

**Security Testing Required:**
- Authentication bypass tests
- Authorization boundary tests
- Input validation fuzzing
- Path traversal tests
- Cross-prompt injection tests

This strategy addresses attack vectors identified in Microsoft's Windows MCP security analysis while maintaining framework usability.
