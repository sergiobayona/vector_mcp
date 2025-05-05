# VectorMCP

<!-- Badges (Add URLs later) -->
[![Gem Version](https://badge.fury.io/rb/vector_mcp.svg)](https://badge.fury.io/rb/vector_mcp)
[![Build Status](https://github.com/sergiobayona/vector_mcp/actions/workflows/ruby.yml/badge.svg)](https://github.com/sergiobayona/vector_mcp/actions/workflows/ruby.yml)
[![Maintainability](https://api.codeclimate.com/v1/badges/YOUR_BADGE_ID/maintainability)](https://codeclimate.com/github/sergiobayona/vector_mcp/maintainability)
[![Test Coverage](https://api.codeclimate.com/v1/badges/YOUR_BADGE_ID/test_coverage)](https://codeclimate.com/github/sergiobayona/vector_mcp/test_coverage)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

VectorMCP provides server-side tools for implementing the [Model Context Protocol (MCP)](https://modelcontext.dev/) in Ruby applications. MCP is a specification for how Large Language Models (LLMs) can discover and interact with external tools, resources, and prompts provided by separate applications (MCP Servers).

This library allows you to easily create MCP servers that expose your application's capabilities (like functions, data sources, or predefined prompt templates) to compatible LLM clients (e.g., Claude Desktop App, custom clients).

## Features

*   **MCP Specification Adherence:** Implements core server-side aspects of the MCP specification.
*   **Tools:** Define and register custom tools (functions) that the LLM can invoke.
*   **Resources:** Expose data sources (files, database results, API outputs) for the LLM to read.
*   **Prompts:** Provide structured prompt templates the LLM can request and use.
*   **Multiple Transports:**
    *   **Stdio:** Simple transport using standard input/output, ideal for process-based servers.
    *   **SSE (Server-Sent Events):** Asynchronous network transport using the modern [`async`/`falcon`](https://github.com/socketry/async) ecosystem.
*   **Extensible Handlers:** Provides default handlers for core MCP methods, which can be overridden.
*   **Clear Error Handling:** Custom error classes mapping to JSON-RPC/MCP error codes.
*   **Ruby-like API:** Uses blocks for registering handlers, following idiomatic Ruby patterns.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'vector_mcp'
```

And then execute:

```bash
$ bundle install
```

Or install it yourself as:

```bash
$ gem install vector_mcp
```

Note: The SSE transport requires additional gems (`async`, `async-http`, `falcon`, `rack`). These will be installed automatically if you install `vector_mcp`.

## Quick Start (Stdio Example)

This example creates a simple server that runs over standard input/output and provides one tool.

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

require 'vector_mcp'

# Optional: Set log level (DEBUG, INFO, WARN, ERROR, FATAL)
VectorMCP.logger.level = Logger::INFO

# 1. Create a server instance
server = VectorMCP.new(name: "MySimpleStdioServer", version: "1.0")

# 2. Register a tool
server.register_tool(
  name: "simple_echo",
  description: "Echoes back the provided message.",
  # Define expected input using JSON Schema format
  input_schema: {
    type: "object",
    properties: {
      message: { type: "string", description: "The message to echo." }
    },
    required: ["message"]
  }
  # The block receives arguments (hash) and the session object
) do |args, _session|
  input = args["message"] || args[:message] # Handle string/symbol keys
  server.logger.info "Echoing: #{input}"
  # The return value will be converted to MCP 'content' format
  "You sent: #{input}"
end

# 3. Run the server using the stdio transport
begin
  server.run(transport: :stdio)
rescue Interrupt
  VectorMCP.logger.info("Server stopped.")
rescue StandardError => e
  VectorMCP.logger.fatal("Server crashed: #{e.message}\n#{e.backtrace.join("\n")}")
  exit 1
end
```

**To run this:**

1.  Save it as `my_server.rb`.
2.  Run `ruby my_server.rb`.
3.  The server is now listening on stdin/stdout. You can interact with it by sending JSON-RPC messages (see MCP specification):

    *   **Send Initialize:**
        ```json
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"ManualClient","version":"0.1"}}}
        ```
    *   **(Server Responds)**
    *   **Send Initialized:**
        ```json
        {"jsonrpc":"2.0","method":"initialized","params":{}}
        ```
    *   **List Tools:**
        ```json
        {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
        ```
    *   **(Server Responds with `simple_echo` tool definition)**
    *   **Call Tool:**
        ```json
        {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"simple_echo","arguments":{"message":"Hello VectorMCP!"}}}
        ```
    *   **(Server Responds with echo result)**

## Usage

### Creating a Server

Instantiate the server using the factory method:

```ruby
require 'vector_mcp'

server = VectorMCP.new(
  name: "MyAwesomeServer",
  version: "2.1.0",
  log_level: Logger::DEBUG # Optional: Default is INFO
)
```

### Registering Tools

Tools are functions your server exposes. Use `register_tool` with a block.

```ruby
server.register_tool(
  name: "calculate_sum",
  description: "Adds two numbers together.",
  input_schema: {
    type: "object",
    properties: {
      a: { type: "number", description: "First number" },
      b: { type: "number", description: "Second number" }
    },
    required: ["a", "b"]
  }
) do |args, session|
  # args is a hash like { "a" => 10, "b" => 5 }
  # session object provides session context (e.g., session.initialized?)
  sum = (args["a"] || 0) + (args["b"] || 0)
  "The sum is: #{sum}" # Return value is converted to {type: "text", text: ...}
end
```

*   The `input_schema` must be a Hash representing a valid JSON Schema object describing the tool's expected arguments.
*   The block receives the arguments hash and the `VectorMCP::Session` object.
*   The block's return value is automatically converted into the MCP `content` array format by `VectorMCP::Util.convert_to_mcp_content`. You can return:
    *   A `String`: Becomes `{ type: 'text', text: '...' }`.
    *   A `Hash` matching the MCP content structure (`{ type: 'text', ... }`, `{ type: 'image', ... }`, etc.): Used as is.
    *   Other `Hash` objects: JSON-encoded into `{ type: 'text', text: '...', mimeType: 'application/json' }`.
    *   Binary String (`Encoding::ASCII_8BIT`): Base64-encoded into `{ type: 'blob', blob: '...', mimeType: 'application/octet-stream' }`.
    *   An `Array` of the above: Each element is converted and combined.
    *   Other objects: Converted using `to_s` into `{ type: 'text', text: '...' }`.

### Registering Resources

Resources provide data that the client can read.

```ruby
server.register_resource(
  uri: "memory://status", # Unique URI for this resource
  name: "Server Status",
  description: "Provides the current server status.",
  mime_type: "application/json" # Optional: Defaults to text/plain
) do |session|
  # Handler block receives the session object
  {
    status: "OK",
    uptime: Time.now - server_start_time, # Example value
    initialized: session.initialized?
  } # Hash will be JSON encoded due to mime_type
end

# Resource returning binary data
server.register_resource(
  uri: "file://logo.png",
  name: "Logo Image",
  description: "The server's logo.",
  mime_type: "image/png"
) do |session|
  # IMPORTANT: Return binary data as a string with ASCII-8BIT encoding
  File.binread("path/to/logo.png")
end
```

*   The block receives the `VectorMCP::Session` object.
*   Return `String` for text, or a binary `String` (`Encoding::ASCII_8BIT`) for binary data. Other types are generally JSON-encoded.

### Registering Prompts

Prompts provide templates for the client/LLM.

```ruby
server.register_prompt(
  name: "summarize_document",
  description: "Creates a prompt to summarize a document.",
  # Define arguments the client can provide
  arguments: [
    { name: "doc_uri", description: "URI of the document resource to summarize.", required: true },
    { name: "length", description: "Desired summary length (e.g., 'short', 'medium', 'long').", required: false }
  ]
) do |args, session|
  # args is a hash like { "doc_uri" => "file://...", "length" => "short" }
  doc_uri = args["doc_uri"]
  length_hint = args["length"] ? " Keep the summary #{args['length']}." : ""

  # Handler must return an array of message hashes
  [
    {
      role: "user",
      content: { type: "text", text: "Please summarize the following document.#{length_hint}" }
    },
    # You might read the resource here to include its content, or let the client do it
    # Example: Reading resource inside prompt handler (use with caution for large files)
    # begin
    #   # Note: read_resource handler itself runs in the server context
    #   # Accessing it directly here might block if not careful.
    #   # A better pattern might be to just reference the URI.
    #   resource_content = server.resources[doc_uri]&.handler&.call(session) || "[Document content not found]"
    #   {
    #     role: "user",
    #     content: { type: "text", text: "Document Content:\n#{resource_content}" }
    #   }
    # rescue => e
    #   { role: "user", content: { type: "text", text: "[Error reading document: #{e.message}]"} }
    # end
    # Example: Referencing the resource URI (preferred)
    {
      role: "user",
      # This assumes the client understands how to fetch and include the resource content
      content: { type: "text", text: "Document to Summarize URI: #{doc_uri}" }
    }
  ]
end
```

*   The `arguments` array describes parameters the client can pass when requesting the prompt.
*   The block receives the arguments hash and the session.
*   The block **must** return an Array of Hashes, where each hash conforms to the MCP `PromptMessage` structure (`{ role: 'user'|'assistant', content: { type: 'text'|'image'|'resource', ... } }`).

### Running the Server

Use the `run` method, specifying the desired transport.

**Stdio:**

```ruby
server.run(transport: :stdio)
```

**SSE:**

Requires the `async`, `falcon`, etc. gems.

```ruby
server.run(
  transport: :sse,
  options: {
    host: "0.0.0.0",        # Default: 'localhost'
    port: 8080,             # Default: 8000
    path_prefix: "/my_mcp"  # Default: '/mcp'. Endpoints become /my_mcp/sse and /my_mcp/message
  }
)
```

The SSE server uses Falcon and runs asynchronously. Use Ctrl+C (SIGINT) or SIGTERM to stop it gracefully.

### Custom Handlers

You can override default handlers or add handlers for non-standard methods:

```ruby
# Override default ping
server.on_request("ping") do |_params, _session, _server|
  { received_ping_at: Time.now }
end

# Handle a custom notification
server.on_notification("custom/my_event") do |params, session, server|
  server.logger.info "Received my_event: #{params.inspect}"
  # Do something...
end
```

## Architecture

*   **`VectorMCP::Server`:** The main class. Manages registration, state, and dispatches incoming messages to appropriate handlers.
*   **`VectorMCP::Transport::{Stdio, SSE}`:** Handle the specifics of communication over different channels (stdin/stdout or HTTP SSE). They read raw data, parse JSON, call `Server#handle_message`, and send back formatted JSON-RPC responses/errors.
*   **`VectorMCP::Session`:** Holds state related to a specific client connection, primarily the initialization status and negotiated capabilities. Passed to handlers.
*   **`VectorMCP::Definitions::{Tool, Resource, Prompt}`:** Simple structs holding registered capability information and handler blocks.
*   **`VectorMCP::Handlers::Core`:** Contains default implementations for standard MCP methods.
*   **`VectorMCP::Errors`:** Custom exception classes mapping to JSON-RPC error codes.
*   **`VectorMCP::Util`:** Utility functions.

## Development

After checking out the repo:

1.  Install dependencies:
    ```bash
    $ bundle install
    ```
2.  Run tests:
    ```bash
    $ bundle exec rspec
    ```
3.  Run an example server:
    ```bash
    $ bundle exec ruby examples/stdio_server.rb
    # or
    $ bundle exec ruby examples/simple_server.rb # For SSE
    ```

You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `lib/vector_mcp/version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at [https://github.com/sergiobayona/vector_mcp](https://github.com/sergiobayona/vector_mcp).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

