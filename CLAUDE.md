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

### Key Features

- **Tools**: Custom functions that LLMs can invoke with optional security policies and image support
- **Resources**: Data sources for LLM consumption with access control and image resource helpers
- **Prompts**: Structured prompt templates with image argument support
- **Roots**: Filesystem boundaries for security and workspace context
- **Sampling**: LLM completion requests with streaming, tool calls, and image support
- **Security**: Comprehensive authentication and authorization system
- **Logging**: Component-based structured logging with multiple outputs and formats
- **Image Processing**: Full image handling pipeline with format detection and validation

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
- Follow existing async patterns using the `async` gem
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

**Runtime**: async, async-container, async-http, async-io, base64, falcon
**Development**: rspec, rubocop, simplecov, yard, pry-byebug
**Optional**: jwt (for JWT authentication strategy)

### Version Management

Version defined in `lib/vector_mcp/version.rb` (currently 0.3.0)

## Logging Architecture

VectorMCP includes a production-ready structured logging system with component-based organization and multiple output formats.

### Logging Features

**✅ Component-Based Logging**
- **Component Loggers**: `VectorMCP.logger_for("server")`, `VectorMCP.logger_for("transport.stdio")`
- **Hierarchical Configuration**: Different log levels per component
- **Context Management**: Structured context with `with_context` blocks
- **Performance Measurement**: Built-in `measure` method for operation timing

**✅ Multiple Output Formats**
- **Text Format**: Human-readable with colors and structured layout
- **JSON Format**: Machine-readable for log aggregation systems
- **Console Output**: Interactive development with colored output
- **File Output**: Production logging with rotation support

**✅ Flexible Configuration**
- **Environment Variables**: `VECTORMCP_LOG_LEVEL`, `VECTORMCP_LOG_FORMAT`, `VECTORMCP_LOG_OUTPUT`
- **YAML Configuration**: File-based configuration for complex deployments
- **Programmatic Configuration**: Runtime configuration changes
- **Legacy Compatibility**: Existing `VectorMCP.logger` continues to work

### Logging Usage Examples

**Basic Component Logging:**
```ruby
server_logger = VectorMCP.logger_for("server")
server_logger.info("Server started", context: { port: 8080, transport: "stdio" })
```

**Context Management:**
```ruby
server_logger.with_context(session_id: "sess_123") do
  server_logger.info("Processing request")
  server_logger.warn("Request validation failed")
end
```

**Performance Measurement:**
```ruby
result = server_logger.measure("Database query") do
  # Your operation here
  perform_database_query
end
```

**Configuration Setup:**
```ruby
VectorMCP.setup_logging(level: "DEBUG", format: "json")
VectorMCP.configure_logging do
  level "INFO"
  component "security.auth", level: "DEBUG"
  console colorize: true, include_timestamp: true
end
```

**Security Event Logging:**
```ruby
security_logger = VectorMCP.logger_for("security.auth")
security_logger.security("Authentication successful", context: { 
  user_id: "user_123", 
  strategy: "jwt", 
  ip_address: request_ip 
})
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
- Use structured logging for security event tracking

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
4. **Logging**: Use component loggers for observability during development
5. **Security**: Test with `examples/auth_server.rb` for security scenarios
6. **Documentation**: Update YARD docs and run `rake yard`