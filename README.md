# VectorMCP

<!-- Badges (Add URLs later) -->
[![Gem Version](https://badge.fury.io/rb/vector_mcp.svg)](https://badge.fury.io/rb/vector_mcp)
[![Build Status](https://github.com/sergiobayona/VectorMCP/actions/workflows/ruby.yml/badge.svg?branch=main)](https://github.com/sergiobayona/vector_mcp/actions/workflows/ruby.yml)
[![Maintainability](https://qlty.sh/badges/fdb143b3-148a-4a86-8e3b-4ccebe993528/maintainability.svg)](https://qlty.sh/gh/sergiobayona/projects/VectorMCP)
[![Test Coverage](https://api.codeclimate.com/v1/badges/YOUR_BADGE_ID/test_coverage)](https://codeclimate.com/github/sergiobayona/vector_mcp/test_coverage)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

VectorMCP provides server-side tools for implementing the [Model Context Protocol (MCP)](https://modelcontext.dev/) in Ruby applications. MCP is a specification for how Large Language Models (LLMs) can discover and interact with external tools, resources, and prompts provided by separate applications (MCP Servers).

This library allows you to easily create MCP servers that expose your application's capabilities (like functions, data sources, or predefined prompt templates) to compatible LLM clients (e.g., Claude Desktop App, custom clients).

## Features

*   **MCP Specification Adherence:** Implements core server-side aspects of the MCP specification.
*   **Tools:** Define and register custom tools (functions) that the LLM can invoke.
*   **Resources:** Expose data sources (files, database results, API outputs) for the LLM to read.
*   **Prompts:** Provide structured prompt templates the LLM can request and use.
*   **Transport:**
    *   **Stdio (stable):** Simple transport using standard input/output, ideal for process-based servers.
    *   **SSE (work-in-progress):** Server-Sent Events support is under active development and currently unavailable.
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

> ⚠️  **Heads-up:** SSE transport is not yet supported in the released gem. When it lands it will require additional gems (`async`, `async-http`, `falcon`, `rack`).

## Quick Start

This example creates a simple server that runs over standard input/output and provides one tool.

```ruby
require 'vector_mcp'

# Create a server
server = VectorMCP.new('Echo Server')

# Register a single "echo" tool
server.register_tool(
  name: 'echo',
  description: 'Returns whatever message you send.',
  input_schema: {
    type: 'object',
    properties: { message: { type: 'string' } },
    required: ['message']
  }
) { |args, _session| args['message'] }

# Start listening on STDIN/STDOUT (default transport)
server.run
```

**To run this:**

1.  Save it as `my_server.rb`.
2.  Run `ruby my_server.rb`.
3.  The server now waits for **newline-delimited JSON-RPC objects** on **STDIN** and writes responses to **STDOUT**.

   You have two easy ways to talk to it:

   **a. Interactive (paste a line, press Enter)**

   ```bash
   $ ruby my_server.rb
   # paste the JSON below, press ↵, observe the response
   {"jsonrpc":"2.0","id":1,"method":"initialize","params":{...}}
   {"jsonrpc":"2.0","method":"initialized"}
   # etc.
   ```

   **b. Scripted (pipe a series of echo / printf commands)**

   ```bash
   { 
     printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"CLI","version":"0.1"}}}';
     printf '%s\n' '{"jsonrpc":"2.0","method":"initialized"}';
     printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}';
     printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"message":"Hello VectorMCP!"}}}';
   } | ruby my_server.rb | jq  # jq formats the JSON responses
   ```

   Each request **must be on a single line and terminated by a newline** so the server knows where the message ends.

   Below are the same requests shown individually:

```jsonc
// 1. Initialize (client → server)
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"ManualClient","version":"0.1"}}}

// 2. Initialized notification (client → server, no id)
{"jsonrpc":"2.0","method":"initialized"}

// 3. List available tools (client → server)
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}

// 4. Call the echo tool (client → server)
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"message":"Hello VectorMCP!"}}}
```

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

*   The input_schema must be a Hash representing a valid JSON Schema object describing the tool's expected arguments.
*   The block receives the arguments hash and the VectorMCP::Session object.
*   The **session** object represents the client connection that invoked the tool. It lets you:
    * Inspect the client's `clientInfo` and declared `capabilities` (e.g. `session.client_info['name']`).
    * Store or look up per-connection state (authentication, rate-limiting, feature flags).
    * Send follow-up notifications or streaming updates back only to that client.
    * Check whether the session is already `initialized?` before doing expensive work.

    Passing `session` up-front means tool authors can make use of this context today; if you don't need it, simply ignore the parameter (Ruby will accept extra block parameters).
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
*   Return `String` for text, or a binary `