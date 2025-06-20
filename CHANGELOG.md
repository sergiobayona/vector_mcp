## Unreleased

## [0.3.0] – 2025-06-20

### Added
* **Comprehensive Input Schema Validation**: Two-layer validation system for enhanced security and developer experience
  - **Schema Validation**: Validates JSON Schema format during tool registration using `json-schema` gem
  - **Input Validation**: Validates user arguments against defined schemas during tool execution
  - Automatic validation for all tools with `input_schema` defined
  - Detailed error messages with specific validation failure details
  - Full backward compatibility - tools without schemas continue working unchanged
  - New `validate_schema_format!` method for registration-time validation
  - Renamed `validate_tool_arguments!` to `validate_input_arguments!` for clarity

* **Enhanced Documentation and Examples**
  - Comprehensive README section on automatic input validation with security benefits
  - New `examples/validation_demo.rb` showcasing both validation types
  - Complete `examples/README.md` with descriptions of all example files
  - Updated documentation emphasizing security best practices

### Changed
* **Method Naming Improvements**: Clarified validation method names
  - `validate_tool_arguments!` → `validate_input_arguments!` (runtime validation)
  - Added `validate_schema_format!` (registration-time validation)

### Security
* **Injection Attack Prevention**: Centralized validation prevents malformed input from reaching tool handlers
* **Type Safety**: Ensures all arguments match expected JSON Schema types and constraints
* **Early Error Detection**: Invalid schemas caught during development, not runtime

* **SSE Transport Implementation**: Complete HTTP/Server-Sent Events transport
  - New `VectorMCP::Transport::SSE` class with HTTP server capabilities
  - Puma-based HTTP server with concurrent request handling
  - Bi-directional communication: SSE for server-to-client, HTTP POST for client-to-server
  - Session management with unique session IDs and connection tracking
  - Support for web browsers and HTTP-based MCP clients
  - Configurable host, port, and path prefix options

## [0.2.0] – 2025-05-26

### Added
* **MCP Sampling Support**: Full implementation of Model Context Protocol sampling capabilities
  - New `VectorMCP::Sampling::Request` and `VectorMCP::Sampling::Result` classes
  - Session-based sampling with `Session#sample` method
  - Configurable sampling capabilities (methods, features, limits, context inclusion)
  - Support for streaming, tool calls, images, and model preferences
  - Timeout and error handling for sampling requests

* **Image Processing Utilities**: Comprehensive image handling capabilities
  - New `VectorMCP::ImageUtil` module with format detection, validation, and conversion
  - Support for JPEG, PNG, GIF, WebP, BMP, and TIFF formats
  - Base64 encoding/decoding with validation
  - Image metadata extraction (dimensions, format, size)
  - MCP-compliant image content generation
  - File-based and binary data image processing

* **Enhanced Definitions**: Extended tool, resource, and prompt definitions
  - Image support detection for tools (`Tool#supports_image_input?`)
  - Image resource creation (`Resource.from_image_file`, `Resource.from_image_data`)
  - Image-aware prompts (`Prompt#supports_image_arguments?`, `Prompt.with_image_support`)
  - Enhanced validation and MCP definition generation

* **Roots Support**: New MCP roots functionality
  - `VectorMCP::Definitions::Root` class for filesystem root definitions
  - Root registration and validation (`Server#register_root`, `Server#register_root_from_path`)
  - Automatic path validation and security checks
  - List change notifications for roots

* **Enhanced Content Utilities**: Improved content processing in `VectorMCP::Util`
  - Automatic image file path detection and processing
  - Binary image data detection and conversion
  - Mixed content array processing with image support
  - Enhanced JSON-RPC ID extraction from malformed messages

### Changed
* **Server Architecture Refactoring**: Major code organization improvements
  - Extracted server functionality into focused modules:
    - `VectorMCP::Server::Registry` for tool/resource/prompt management
    - `VectorMCP::Server::Capabilities` for capability negotiation
    - `VectorMCP::Server::MessageHandling` for request/notification processing
  - Reduced main `Server` class from 392 to 159 lines
  - Improved separation of concerns and maintainability

* **Enhanced Session Management**: Improved session initialization and state handling
  - Better session lifecycle management
  - Enhanced sampling capabilities integration
  - Improved error handling for uninitialized sessions

* **Transport Layer Improvements**: Enhanced stdio transport reliability
  - Better request/response correlation for server-initiated requests
  - Improved error handling and timeout management
  - Enhanced thread safety and resource cleanup
  - Fixed session initialization race conditions

* **Error Handling Enhancements**: More robust error management
  - Additional error types for sampling operations
  - Better error context and details
  - Improved protocol error handling

### Fixed
* **Code Quality Improvements**: Resolved all Ruby linting violations
  - Fixed method length violations through strategic refactoring
  - Resolved perceived complexity issues by extracting helper methods
  - Eliminated duplicate attribute declarations
  - Fixed parameter list length violations
  - Corrected naming convention violations
  - Removed unused variable assignments

* **Session Initialization**: Fixed double initialization bug in stdio transport
  - Resolved race condition causing "Session already initialized" errors
  - Improved session state management across transport layer
  - Fixed integration test failures related to session handling

* **Test Suite Stability**: Enhanced test reliability and coverage
  - Fixed integration test failures
  - Improved test isolation and cleanup
  - Enhanced error scenario testing
  - Added comprehensive image processing tests

### Technical Details
* **Dependencies**: Added `base64` gem requirement for image processing
* **API Compatibility**: All changes maintain backward compatibility with existing MCP clients
* **Performance**: Improved memory usage through better resource management
* **Security**: Enhanced path validation and traversal protection for roots
* **Documentation**: Updated README with new features and examples

## [0.1.0] – 2025-05-08
### Added
* First public release: stdio transport, tool/resource registration, JSON-RPC layer…
