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
ruby examples/http_server.rb        # HTTP server example
```

## Architecture

### Core Components

- **VectorMCP::Server** (`lib/vector_mcp/server.rb`): Main server class handling MCP protocol
- **Transport Layer** (`lib/vector_mcp/transport/`): Communication protocols
  - `Stdio`: Standard input/output (stable)
  - `Sse`: Server-Sent Events (work in progress)
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

1. Client connects via transport layer (stdio/SSE)
2. JSON-RPC messages processed by server registry
3. Handlers dispatch to registered tools/resources/prompts
4. Responses formatted according to MCP specification

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

Version defined in `lib/vector_mcp/version.rb` (currently 0.2.0)
