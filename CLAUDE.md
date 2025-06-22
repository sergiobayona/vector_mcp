# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

VectorMCP is a Ruby gem implementing the Model Context Protocol (MCP) server-side specification. It provides a framework for creating MCP servers that expose tools, resources, prompts, and roots to LLM clients with comprehensive security features.

## Essential Commands

### Development Setup

```bash
bin/setup          # Install dependencies and setup development environment
bin/console        # Interactive Ruby console with the gem loaded
```

### Testing and Quality

```bash
rake               # Run default task (tests + linting)
bundle exec rspec          # Run RSpec test suite  
bundle exec rspec ./spec/vector_mcp/examples_spec.rb # run a single test file
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
ruby examples/auth_server.rb        # Authentication and authorization demo
ruby examples/validation_demo.rb    # Input validation examples
ruby examples/cli_client.rb         # Command-line client example
```

## Architecture

### Core Components

- **VectorMCP::Server** (`lib/vector_mcp/server.rb`): Main server class handling MCP protocol with security integration
- **Transport Layer** (`lib/vector_mcp/transport/`): Communication protocols
  - `Stdio`: Standard input/output (stable)
  - `Sse`: Server-Sent Events over HTTP (stable) with security middleware
- **Handlers** (`lib/vector_mcp/handlers/`): Request processing logic with authorization checks
- **Sampling** (`lib/vector_mcp/sampling/`): Server-initiated LLM requests with streaming support
- **Definitions** (`lib/vector_mcp/definitions.rb`): Tool, Resource, and Prompt definitions
- **Security** (`lib/vector_mcp/security/`): Authentication and authorization framework

### Key Features

- **Tools**: Custom functions that LLMs can invoke with optional security policies
- **Resources**: Data sources for LLM consumption with access control
- **Prompts**: Structured prompt templates
- **Roots**: Filesystem boundaries for security and workspace context
- **Sampling**: LLM completion requests with streaming, tool calls, and image support
- **Security**: Comprehensive authentication and authorization system

### Request Flow

**Stdio Transport:**
1. Client connects via stdin/stdout
2. Optional authentication via custom session-based strategies
3. JSON-RPC messages processed line-by-line
4. Security middleware processes authentication and authorization
5. Handlers dispatch to registered tools/resources/prompts with session context
6. Responses sent back via stdout

**SSE Transport:**
1. Client establishes SSE connection (`GET /sse`)
2. Server sends session info and message endpoint URL
3. Client sends JSON-RPC requests (`POST /message?session_id=<id>`) with authentication headers
4. Security middleware validates authentication (API key, JWT, or custom)
5. Authorization policies checked for tool/resource access
6. Server processes requests and sends responses via SSE stream
7. Handlers dispatch to registered tools/resources/prompts with authenticated session context
8. All responses formatted according to MCP specification

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
**Optional**: jwt (for JWT authentication strategy)

### Version Management

Version defined in `lib/vector_mcp/version.rb` (currently 0.3.0)

## Security Architecture

VectorMCP includes a comprehensive security framework implementing defense-in-depth principles based on Windows MCP security recommendations.

### Implemented Security Features

**✅ Authentication Framework (`lib/vector_mcp/security/`)**
- **API Key Strategy** - Header and query parameter based authentication
- **JWT Token Strategy** - JSON Web Token validation with configurable algorithms
- **Custom Strategy** - Flexible handler-based authentication for complex scenarios
- **Strategy Management** - Centralized authentication strategy switching

**✅ Authorization System**
- **Policy-Based Access Control** - Fine-grained permissions for tools, resources, and prompts
- **Role-Based Authorization** - User role and permission management
- **Resource-Level Security** - Per-resource access policies
- **Session Context** - Secure session management with user data and permissions

**✅ Security Middleware**
- **Request Processing** - Automatic authentication and authorization checks
- **Transport Integration** - Works across stdio and SSE transports
- **Error Handling** - Secure error responses without information leakage
- **Session Isolation** - Per-request security context management

### Security Usage Examples

**Enable API Key Authentication:**
```ruby
server.enable_authentication!(strategy: :api_key, keys: ["secret-key-123"])
```

**Enable JWT Authentication:**
```ruby
server.enable_authentication!(
  strategy: :jwt_token, 
  secret: "jwt-secret",
  algorithm: "HS256"
)
```

**Enable Custom Authentication:**
```ruby
server.enable_authentication!(strategy: :custom) do |request|
  api_key = request[:headers]["X-API-Key"]
  user_database.authenticate(api_key)
end
```

**Configure Authorization Policies:**
```ruby
server.enable_authorization! do
  authorize_tools do |user, action, tool|
    user[:role] == "admin" || tool.name != "dangerous_tool"
  end
  
  authorize_resources do |user, action, resource|
    user[:permissions].include?("read:#{resource.uri}")
  end
end
```

### Security Testing

**Comprehensive Test Coverage:**
- 68+ authentication strategy tests covering all scenarios
- Transport security integration tests for SSE and stdio
- Authorization policy tests with edge cases
- Error handling and attack scenario validation
- Performance and concurrency security tests

### Remaining Security Enhancements

**Phase 2: Advanced Security (Planned)**
- **Cross-Prompt Injection Prevention** - Content sanitization for LLM safety
- **Tool Execution Sandboxing** - Isolated execution environments
- **Credential Protection** - Secure secret management
- **Session Timeouts** - Automatic session expiration
- **CSRF Protection** - Cross-site request forgery prevention

### Windows-Inspired Security Controls

1. **Proxy-Mediated Communication** - Security middleware layer
2. **Granular Permissions** - Per-tool capability declarations  
3. **Authentication Strategies** - Multiple authentication methods
4. **Runtime Context** - Secure session and user context management
5. **Defense in Depth** - Multiple security layers

### Security Best Practices

- Always enable authentication for production deployments
- Use JWT tokens for stateless authentication in distributed systems
- Implement least-privilege authorization policies
- Regularly audit and test security configurations
- Monitor authentication failures and suspicious activity
