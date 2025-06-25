## Unreleased

### Added
* **Enhanced Structured Logging System**: Production-ready logging framework with comprehensive observability features
  - **Component-Based Logging**: Hierarchical logger system with component-specific configuration (`server`, `transport.stdio`, `security.auth`)
  - **Multiple Output Formats**: Text (with colors) and JSON formatters for different deployment needs
  - **Flexible Configuration**: Support for environment variables, YAML files, and programmatic configuration
  - **Context Management**: Structured context passing with `with_context` blocks and persistent context addition
  - **Performance Measurement**: Built-in `measure` method for operation timing and performance monitoring
  - **Log Level Management**: Component-specific log levels with runtime configuration changes
  - **Legacy Compatibility**: Seamless backward compatibility with existing `VectorMCP.logger` usage
  - **Thread Safety**: Concurrent logging support with proper synchronization
  - **Security Logging**: Dedicated security log level for authentication and authorization events

* **Comprehensive Security Framework**: Production-ready authentication and authorization system
  - **Authentication Strategies**: Multiple authentication methods with pluggable architecture
    - **API Key Authentication**: Header and query parameter support with multiple key management
    - **JWT Token Authentication**: JSON Web Token validation with configurable algorithms and secret management
    - **Custom Authentication**: Flexible handler-based authentication for complex integration scenarios
  - **Authorization System**: Fine-grained access control with policy-based permissions
    - **Resource-Level Authorization**: Separate policies for tools, resources, prompts, and roots
    - **Role-Based Access Control**: User role and permission management with session context
    - **Action-Based Permissions**: Granular control over read, write, execute, and administrative actions
  - **Security Middleware**: Comprehensive request processing pipeline
    - **Request Normalization**: Consistent security processing across stdio and SSE transports
    - **Session Context Management**: Secure user session tracking with authentication state
    - **Error Handling**: Secure error responses without information leakage
  - **Transport Integration**: Seamless security across all transport layers
    - **SSE Transport Security**: Full HTTP header and query parameter authentication support
    - **Stdio Transport Security**: Header simulation for desktop application authentication
    - **Rack Environment Processing**: Native HTTP request processing with proper header extraction

* **Enhanced Core Handlers**: Security-aware request processing
  - **Tool Execution Security**: Authentication and authorization checks for tool calls
  - **Resource Access Security**: Protected resource reading with access control policies
  - **Backward Compatibility**: Automatic detection of security-aware vs legacy tool handlers
  - **Session Context Injection**: Optional session context parameter for security-aware handlers

* **New Security Error Types**: Proper MCP error codes for security scenarios
  - **UnauthorizedError (-32401)**: Authentication required error with proper MCP formatting
  - **ForbiddenError (-32403)**: Authorization failed error for access control violations

* **Security Examples and Documentation**
  - **Authentication Example Server** (`examples/auth_server.rb`): Complete demonstration of all security features
  - **Comprehensive Security Guide** (`security/README.md`): 400+ line documentation covering all security aspects
  - **Updated Main Documentation**: Enhanced README with security feature overview and quick start examples
  - **CLAUDE.md Integration**: Updated project documentation with security architecture details

### Changed

* **Code Quality Improvements**: Enhanced maintainability and consistency across the logging system
  * **Constants Refactoring**: Extracted magic numbers to named constants for better maintainability
    * Created `VectorMCP::Logging::Constants` module with self-documenting constant names
    * Replaced hardcoded values (5, 3, 1000, etc.) with meaningful names (`MAX_SERIALIZATION_DEPTH`, `DEFAULT_MAX_MESSAGE_LENGTH`)
    * Centralized configuration limits for JSON serialization, text formatting, and timestamp precision
  * **Enhanced Error Handling**: Improved JSON serialization fallback mechanisms with data sanitization
  * **Consistent Formatting**: Standardized width and truncation behavior across all formatters

* **Opt-In Security Design**: Security features are disabled by default for maximum compatibility
  * Existing servers continue working without modification
  * Security features enabled explicitly via `enable_authentication!` and `enable_authorization!`
  * Zero-configuration default maintains backward compatibility

* **Server Architecture Enhancement**: Security integration into core server functionality
  * **Security Middleware Integration**: Built-in security processing pipeline
  * **Strategy Management**: Centralized authentication strategy switching and cleanup
  * **Session Context Tracking**: Per-request security state management

* **Enhanced Error Handling**: Security-aware error processing throughout the stack
  * Proper MCP error codes for authentication and authorization failures
  * Secure error messages that don't leak sensitive information
  * Graceful degradation with detailed logging for debugging

### Security

* **Defense in Depth**: Multiple security layers following enterprise security principles
  * **Authentication Layer**: Verify user identity before granting access
  * **Authorization Layer**: Fine-grained permission checking for all resources
  * **Transport Security**: Secure communication across all transport mechanisms
  * **Input Validation**: Continued protection against injection attacks via existing schema validation

* **Secure Defaults**: Security-first configuration options
  * Authentication disabled by default (explicit opt-in required)
  * Authorization uses allowlist approach (deny by default, explicit permissions required)
  * Secure error handling without information disclosure
  * Automatic session isolation and cleanup

* **Enterprise Security Features**: Production-ready security controls
  * **Session Management**: Secure user session tracking with authentication state
  * **Permission Framework**: Flexible role-based and resource-based access control
  * **Error Recovery**: Graceful handling of authentication failures, timeouts, and edge cases
  * **Audit Trail**: Comprehensive logging of authentication and authorization events

### Testing

* **Comprehensive Security Test Suite**: 68+ tests covering all security scenarios
  * **Authentication Strategy Tests**: Complete coverage of API key, JWT, and custom authentication
  * **Authorization Policy Tests**: Fine-grained permission testing with edge cases
  * **Transport Security Integration**: End-to-end security testing across stdio and SSE transports
  * **Error Handling Tests**: Security failure scenarios and attack vector validation
  * **Concurrency Tests**: Thread safety and concurrent access security validation
  * **Performance Tests**: Memory management and resource cleanup under load

### Technical Details

* **Dependencies**: Optional JWT gem support for JWT authentication strategy
* **API Compatibility**: All security features maintain full backward compatibility
* **Performance**: Minimal overhead when security is disabled, efficient processing when enabled
* **Documentation**: Extensive security documentation with real-world examples and best practices

## [0.3.0] – 2025-06-20

### Added

* **Comprehensive Input Schema Validation**: Two-layer validation system for enhanced security and developer experience
  * **Schema Validation**: Validates JSON Schema format during tool registration using `json-schema` gem
  * **Input Validation**: Validates user arguments against defined schemas during tool execution
  * Automatic validation for all tools with `input_schema` defined
  * Detailed error messages with specific validation failure details
  * Full backward compatibility - tools without schemas continue working unchanged
  * New `validate_schema_format!` method for registration-time validation
  * Renamed `validate_tool_arguments!` to `validate_input_arguments!` for clarity

* **Enhanced Documentation and Examples**
  * Comprehensive README section on automatic input validation with security benefits
  * New `examples/validation_demo.rb` showcasing both validation types
  * Complete `examples/README.md` with descriptions of all example files
  * Updated documentation emphasizing security best practices

### Changed

* **Method Naming Improvements**: Clarified validation method names
  * `validate_tool_arguments!` → `validate_input_arguments!` (runtime validation)
  * Added `validate_schema_format!` (registration-time validation)

### Security

* **Injection Attack Prevention**: Centralized validation prevents malformed input from reaching tool handlers
* **Type Safety**: Ensures all arguments match expected JSON Schema types and constraints
* **Early Error Detection**: Invalid schemas caught during development, not runtime

* **SSE Transport Implementation**: Complete HTTP/Server-Sent Events transport
  * New `VectorMCP::Transport::SSE` class with HTTP server capabilities
  * Puma-based HTTP server with concurrent request handling
  * Bi-directional communication: SSE for server-to-client, HTTP POST for client-to-server
  * Session management with unique session IDs and connection tracking
  * Support for web browsers and HTTP-based MCP clients
  * Configurable host, port, and path prefix options

## [0.2.0] – 2025-05-26

### Added

* **MCP Sampling Support**: Full implementation of Model Context Protocol sampling capabilities
  * New `VectorMCP::Sampling::Request` and `VectorMCP::Sampling::Result` classes
  * Session-based sampling with `Session#sample` method
  * Configurable sampling capabilities (methods, features, limits, context inclusion)
  * Support for streaming, tool calls, images, and model preferences
  * Timeout and error handling for sampling requests

* **Image Processing Utilities**: Comprehensive image handling capabilities
  * New `VectorMCP::ImageUtil` module with format detection, validation, and conversion
  * Support for JPEG, PNG, GIF, WebP, BMP, and TIFF formats
  * Base64 encoding/decoding with validation
  * Image metadata extraction (dimensions, format, size)
  * MCP-compliant image content generation
  * File-based and binary data image processing

* **Enhanced Definitions**: Extended tool, resource, and prompt definitions
  * Image support detection for tools (`Tool#supports_image_input?`)
  * Image resource creation (`Resource.from_image_file`, `Resource.from_image_data`)
  * Image-aware prompts (`Prompt#supports_image_arguments?`, `Prompt.with_image_support`)
  * Enhanced validation and MCP definition generation

* **Roots Support**: New MCP roots functionality
  * `VectorMCP::Definitions::Root` class for filesystem root definitions
  * Root registration and validation (`Server#register_root`, `Server#register_root_from_path`)
  * Automatic path validation and security checks
  * List change notifications for roots

* **Enhanced Content Utilities**: Improved content processing in `VectorMCP::Util`
  * Automatic image file path detection and processing
  * Binary image data detection and conversion
  * Mixed content array processing with image support
  * Enhanced JSON-RPC ID extraction from malformed messages

### Changed

* **Server Architecture Refactoring**: Major code organization improvements
  * Extracted server functionality into focused modules:
    * `VectorMCP::Server::Registry` for tool/resource/prompt management
    * `VectorMCP::Server::Capabilities` for capability negotiation
    * `VectorMCP::Server::MessageHandling` for request/notification processing
  * Reduced main `Server` class from 392 to 159 lines
  * Improved separation of concerns and maintainability

* **Enhanced Session Management**: Improved session initialization and state handling
  * Better session lifecycle management
  * Enhanced sampling capabilities integration
  * Improved error handling for uninitialized sessions

* **Transport Layer Improvements**: Enhanced stdio transport reliability
  * Better request/response correlation for server-initiated requests
  * Improved error handling and timeout management
  * Enhanced thread safety and resource cleanup
  * Fixed session initialization race conditions

* **Error Handling Enhancements**: More robust error management
  * Additional error types for sampling operations
  * Better error context and details
  * Improved protocol error handling

### Fixed

* **Code Quality Improvements**: Resolved all Ruby linting violations
  * Fixed method length violations through strategic refactoring
  * Resolved perceived complexity issues by extracting helper methods
  * Eliminated duplicate attribute declarations
  * Fixed parameter list length violations
  * Corrected naming convention violations
  * Removed unused variable assignments

* **Session Initialization**: Fixed double initialization bug in stdio transport
  * Resolved race condition causing "Session already initialized" errors
  * Improved session state management across transport layer
  * Fixed integration test failures related to session handling

* **Test Suite Stability**: Enhanced test reliability and coverage
  * Fixed integration test failures
  * Improved test isolation and cleanup
  * Enhanced error scenario testing
  * Added comprehensive image processing tests

### Technical Details

* **Dependencies**: Added `base64` gem requirement for image processing
* **API Compatibility**: All changes maintain backward compatibility with existing MCP clients
* **Performance**: Improved memory usage through better resource management
* **Security**: Enhanced path validation and traversal protection for roots
* **Documentation**: Updated README with new features and examples

## [0.1.0] – 2025-05-08
### Added
* First public release: stdio transport, tool/resource registration, JSON-RPC layer…
