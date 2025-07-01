# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

VectorMCP is a Ruby gem implementing the Model Context Protocol (MCP) server-side specification. It provides a framework for creating MCP servers that expose tools, resources, prompts, and roots to LLM clients with comprehensive security features, structured logging, and production-ready capabilities.

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
bundle exec rspec ./spec/vector_mcp/logging_spec.rb # run logging tests
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
ruby examples/logging_demo.rb       # Structured logging demonstration
ruby examples/cli_client.rb         # Command-line client example
ruby examples/middleware_examples.rb # Pluggable middleware demonstrations
```

### Logging Configuration

```bash
# Environment-based logging configuration
VECTORMCP_LOG_LEVEL=DEBUG ruby examples/logging_demo.rb
VECTORMCP_LOG_FORMAT=json ruby examples/auth_server.rb
VECTORMCP_LOG_OUTPUT=file VECTORMCP_LOG_FILE_PATH=/tmp/vectormcp.log ruby examples/stdio_server.rb
```

## Architecture

### Core Components

- **VectorMCP::Server** (`lib/vector_mcp/server.rb`): Main server class with modular architecture
  - `Server::Registry` (`lib/vector_mcp/server/registry.rb`): Tool/resource/prompt/root registration
  - `Server::Capabilities` (`lib/vector_mcp/server/capabilities.rb`): Server info and capability management
  - `Server::MessageHandling` (`lib/vector_mcp/server/message_handling.rb`): Request/notification processing
- **Transport Layer** (`lib/vector_mcp/transport/`): Communication protocols
  - `Stdio` (`lib/vector_mcp/transport/stdio.rb`): Standard input/output (stable)
  - `Sse` (`lib/vector_mcp/transport/sse.rb`): Server-Sent Events over HTTP (stable) with enhanced components
    - `SSE::StreamManager`: Server-Sent Events streaming management
    - `SSE::ClientConnection`: Individual client connection handling
    - `SSE::MessageHandler`: SSE-specific message processing
- **Handlers** (`lib/vector_mcp/handlers/`): Request processing logic with authorization checks
- **Sampling** (`lib/vector_mcp/sampling/`): Server-initiated LLM requests with streaming support
- **Definitions** (`lib/vector_mcp/definitions.rb`): Tool, Resource, and Prompt definitions with image support
- **Security** (`lib/vector_mcp/security/`): Authentication and authorization framework
- **Logging** (`lib/vector_mcp/logging/`): Structured logging system with observability features
- **Image Processing** (`lib/vector_mcp/image_util.rb`): Image handling and MCP format conversion
- **Middleware** (`lib/vector_mcp/middleware/`): Pluggable hook system for custom behavior

### Key Features

- **Tools**: Custom functions that LLMs can invoke with optional security policies and image support
- **Resources**: Data sources for LLM consumption with access control and image resource helpers
- **Prompts**: Structured prompt templates with image argument support
- **Roots**: Filesystem boundaries for security and workspace context
- **Sampling**: LLM completion requests with streaming, tool calls, and image support
- **Security**: Comprehensive authentication and authorization system
- **Logging**: Component-based structured logging with multiple outputs and formats
- **Image Processing**: Full image handling pipeline with format detection and validation
- **Middleware**: Pluggable hooks for custom behavior around all MCP operations

### Request Flow

**Stdio Transport:**
1. Client connects via stdin/stdout
2. Optional authentication via custom session-based strategies
3. JSON-RPC messages processed line-by-line
4. Security middleware processes authentication and authorization
5. Structured logging captures all events with context
6. Handlers dispatch to registered tools/resources/prompts with session context
7. Responses sent back via stdout

**SSE Transport:**
1. Client establishes SSE connection (`GET /sse`)
2. Server sends session info and message endpoint URL
3. Client sends JSON-RPC requests (`POST /message?session_id=<id>`) with authentication headers
4. Security middleware validates authentication (API key, JWT, or custom)
5. Authorization policies checked for tool/resource access
6. Structured logging tracks all security and transport events
7. Server processes requests and sends responses via SSE stream
8. Handlers dispatch to registered tools/resources/prompts with authenticated session context
9. All responses formatted according to MCP specification

## Development Guidelines

### Code Structure

- Use `lib/vector_mcp/` for core functionality
- Place examples in `examples/` directory
- Tests go in `spec/` with matching directory structure
- Follow existing concurrency patterns using Ruby threading and concurrent-ruby
- Structured logging available via `VectorMCP.logger_for(component)`

### Error Handling

Use VectorMCP-specific error classes:

- `VectorMCP::InvalidRequestError`
- `VectorMCP::MethodNotFoundError`
- `VectorMCP::InvalidParamsError`
- `VectorMCP::NotFoundError`
- `VectorMCP::InternalError`
- `VectorMCP::SamplingTimeoutError`
- `VectorMCP::SamplingError`
- `VectorMCP::UnauthorizedError` (security)
- `VectorMCP::ForbiddenError` (security)

### Testing

- Run tests with `rake spec` before committing
- Use RSpec for behavior-driven testing
- Test coverage tracked with SimpleCov (coverage/ directory)
- Ensure rubocop passes with `rake rubocop`
- New test categories: logging, image processing, SSE components

### Dependencies

**Runtime**: base64, concurrent-ruby, json-schema, jwt, puma, rack
**Development**: rspec, rubocop, simplecov, yard, pry-byebug
**Optional**: jwt (for JWT authentication strategy)

### Version Management

Version defined in `lib/vector_mcp/version.rb` (currently 0.3.0)

## Logging

VectorMCP provides simple, environment-driven logging with support for structured JSON output and component identification.

### Basic Usage

**Component Loggers:**
```ruby
server_logger = VectorMCP.logger_for("server")
server_logger.info("Server started", port: 8080, transport: "stdio")
```

**Performance Measurement:**
```ruby
result = server_logger.measure("Database query") do
  perform_database_query
end
```

**Security Logging:**
```ruby
security_logger = VectorMCP.logger_for("security")
security_logger.security("Authentication failed", user_id: "user_123", reason: "invalid_key")
```

### Configuration

All configuration is done via environment variables:

- `VECTORMCP_LOG_LEVEL`: DEBUG, INFO, WARN, ERROR, FATAL (default: INFO)
- `VECTORMCP_LOG_FORMAT`: text, json (default: text)
- `VECTORMCP_LOG_OUTPUT`: stderr, stdout, file (default: stderr)
- `VECTORMCP_LOG_FILE`: File path when using file output (default: ./vectormcp.log)

**Examples:**
```bash
# JSON logging to file
VECTORMCP_LOG_FORMAT=json VECTORMCP_LOG_OUTPUT=file ruby server.rb

# Debug level with text format
VECTORMCP_LOG_LEVEL=DEBUG ruby server.rb
```

## Image Processing

VectorMCP provides comprehensive image handling capabilities for MCP image content.

### Image Features

**✅ Format Detection and Validation**
- **Supported Formats**: JPEG, PNG, GIF, WebP, BMP, TIFF
- **Magic Byte Detection**: Automatic format detection from binary data
- **Size Validation**: Configurable maximum file size limits
- **MIME Type Validation**: Ensure proper image content types

**✅ MCP Integration**
- **Image Resources**: `VectorMCP::Definitions::Resource.from_image_file(path)`
- **Image Tools**: Tools with `supports_image_input?` detection
- **Image Prompts**: Prompts with `supports_image_arguments?` detection
- **Base64 Conversion**: Automatic MCP-compliant image content generation

### Image Usage Examples

**Register Image Resource:**
```ruby
# From file
image_resource = VectorMCP::Definitions::Resource.from_image_file(
  "/path/to/image.jpg",
  name: "company_logo",
  description: "Company logo for branding"
)

# From binary data
image_resource = VectorMCP::Definitions::Resource.from_image_data(
  binary_data,
  mime_type: "image/png",
  name: "generated_chart"
)
```

**Image-Aware Tools:**
```ruby
image_tool = VectorMCP::Definitions::Tool.new(
  name: "analyze_image",
  description: "Analyze uploaded images",
  input_schema: {
    type: "object",
    properties: {
      image: { type: "string", format: "uri" },
      analysis_type: { type: "string", enum: ["objects", "text", "colors"] }
    }
  }
) { |arguments, session_context| 
  # Tool handler with image support
}

puts image_tool.supports_image_input? # => true
```

**Image Processing Utilities:**
```ruby
# Format detection
format = VectorMCP::ImageUtil.detect_image_format(image_data)

# Validation
VectorMCP::ImageUtil.validate_image(image_data, max_size: 5_000_000)

# MCP content generation
mcp_content = VectorMCP::ImageUtil.to_mcp_image_content(image_data)
```

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
- 80+ authentication strategy tests covering all scenarios
- Transport security integration tests for SSE and stdio
- Authorization policy tests with edge cases
- Error handling and attack scenario validation
- Performance and concurrency security tests

### Security Documentation

**Comprehensive Security Guide:**
- **Location**: `security/README.md` (400+ lines)
- **Coverage**: Complete authentication and authorization guide
- **Examples**: Multi-tenant SaaS patterns and API gateway integration
- **Best Practices**: Production deployment recommendations
- **Troubleshooting**: Common security configuration issues

### Security Best Practices

- Always enable authentication for production deployments
- Use JWT tokens for stateless authentication in distributed systems
- Implement least-privilege authorization policies
- Regularly audit and test security configurations
- Monitor authentication failures and suspicious activity
- Use structured logging for security event tracking

## Middleware System

VectorMCP provides a comprehensive middleware framework that allows developers to inject custom behavior around all MCP operations without modifying core code.

### Middleware Architecture

**✅ Hook Points Available:**
- **Tool Operations**: `before_tool_call`, `after_tool_call`, `on_tool_error`
- **Resource Operations**: `before_resource_read`, `after_resource_read`, `on_resource_error`
- **Prompt Operations**: `before_prompt_get`, `after_prompt_get`, `on_prompt_error`
- **Sampling Operations**: `before_sampling_request`, `after_sampling_response`, `on_sampling_error`
- **Transport Operations**: `before_request`, `after_response`, `on_transport_error`
- **Authentication**: `before_auth`, `after_auth`, `on_auth_error`

**✅ Core Components:**
- **`VectorMCP::Middleware::Manager`** - Central hook registry and execution engine
- **`VectorMCP::Middleware::Hook`** - Individual hook definition with priority support
- **`VectorMCP::Middleware::Context`** - Execution context passed to hooks
- **`VectorMCP::Middleware::Base`** - Base class for middleware implementations

### Basic Middleware Usage

**Creating Middleware:**
```ruby
class LoggingMiddleware < VectorMCP::Middleware::Base
  def before_tool_call(context)
    logger.info("Tool call started", {
      operation: context.operation_name,
      user_id: context.user&.[](:user_id)
    })
  end

  def after_tool_call(context)
    logger.info("Tool call completed", {
      operation: context.operation_name,
      success: context.success?
    })
  end
end
```

**Registering Middleware:**
```ruby
# Register for specific hooks
server.use_middleware(LoggingMiddleware, [:before_tool_call, :after_tool_call])

# Register with priority (lower numbers execute first)
server.use_middleware(AuthMiddleware, :before_request, priority: 10)

# Register with conditions
server.use_middleware(PiiMiddleware, :after_tool_call, 
  conditions: { only_operations: ['sensitive_tool'] })
```

### Advanced Middleware Features

**Priority-Based Execution:**
```ruby
# High priority middleware (executes first)
server.use_middleware(SecurityMiddleware, :before_tool_call, priority: 10)

# Normal priority middleware (executes after)
server.use_middleware(LoggingMiddleware, :before_tool_call, priority: 100)
```

**Conditional Execution:**
```ruby
# Only run for specific operations
server.use_middleware(ValidationMiddleware, :before_tool_call,
  conditions: { only_operations: ['data_processing', 'file_upload'] })

# Skip for certain users
server.use_middleware(RateLimitMiddleware, :before_tool_call,
  conditions: { except_users: ['admin_user_123'] })
```

**Error Handling and Recovery:**
```ruby
class RetryMiddleware < VectorMCP::Middleware::Base
  def on_tool_error(context)
    if retryable_error?(context.error)
      # Implement retry logic
      context.result = retry_operation(context)
      # Setting result clears the error
    end
  end
end
```

### Built-in Middleware Examples

**PII Redaction:**
- Automatically scrubs sensitive information from inputs and outputs
- Configurable patterns for different data types
- Supports credit cards, SSNs, emails, custom patterns

**Request Retry:**
- Automatic retries with exponential backoff
- Configurable retry counts and delay strategies
- Error classification for retry decisions

**Rate Limiting:**
- Per-user, per-tool rate limiting
- Sliding window implementation
- Configurable limits and time windows

**Enhanced Logging:**
- Business metrics and performance tracking
- Request/response context capture
- Error classification and alerting

### Middleware Development Guidelines

**Best Practices:**
- Keep middleware focused on single concerns
- Use appropriate hook types for your use case
- Handle errors gracefully to avoid breaking the request chain
- Use priority to control execution order
- Test middleware in isolation and integration

**Error Handling:**
```ruby
class SafeMiddleware < VectorMCP::Middleware::Base
  def before_tool_call(context)
    # Always wrap middleware logic in error handling
    perform_middleware_logic(context)
  rescue StandardError => e
    # Log error but don't break the chain
    logger.error("Middleware failed", error: e.message)
    # Don't re-raise unless critical
  end
end
```

**Testing Middleware:**
```ruby
# Test middleware in isolation
middleware = MyMiddleware.new
context = VectorMCP::Middleware::Context.new(...)
middleware.before_tool_call(context)
expect(context.metadata[:custom_key]).to eq("expected_value")

# Test middleware integration
server.use_middleware(MyMiddleware, :before_tool_call)
# Test actual tool calls through handlers
```

### Common Use Cases

**Data Processing Pipeline:**
- Input validation and sanitization
- Output formatting and transformation
- Data encryption/decryption
- Audit trail generation

**Observability:**
- Performance metrics collection
- Distributed tracing integration
- Custom monitoring and alerting
- Business intelligence data capture

**Security Enhancements:**
- Additional authentication checks
- Request/response inspection
- Threat detection and blocking
- Compliance logging

**Development Tools:**
- Request/response debugging
- Performance profiling
- A/B testing support
- Feature flag integration

## Code Quality and Maintenance

### Constants and Configuration

**Centralized Constants:**
- **Location**: `lib/vector_mcp/logging/constants.rb`
- **Purpose**: Self-documenting configuration limits and defaults
- **Examples**: `MAX_SERIALIZATION_DEPTH`, `DEFAULT_MAX_MESSAGE_LENGTH`, `TIMESTAMP_PRECISION`

### Testing Categories

**Core Functionality:**
- Protocol implementation and JSON-RPC handling
- Tool/resource/prompt registration and execution
- Transport layer functionality (stdio, SSE)

**Security:**
- Authentication strategy testing
- Authorization policy validation
- Session context management
- Error handling and attack scenarios

**Logging:**
- Component-based logging functionality
- Multiple output format validation
- Context management and performance measurement
- Configuration and environment variable handling

**Image Processing:**
- Format detection and validation
- MCP content conversion
- File and data-based resource creation
- Error handling for invalid image data

### Development Workflow

1. **Setup**: Run `bin/setup` for development environment
2. **Testing**: Use `rake` for full test suite including linting
3. **Quality**: Ensure `bundle exec rubocop` passes
4. **Logging**: Use `VectorMCP.logger_for(component)` for component-specific logging
5. **Security**: Test with `examples/auth_server.rb` for security scenarios
6. **Documentation**: Update YARD docs and run `rake yard`