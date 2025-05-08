# VectorMCP

<!-- Badges (Add URLs later) -->
[![Gem Version](https://badge.fury.io/rb/vector_mcp.svg)](https://badge.fury.io/rb/vector_mcp)
[![Docs](http://img.shields.io/badge/yard-docs-blue.svg)](https://sergiobayona.github.io/vector_mcp/)
[![Build Status](https://github.com/sergiobayona/VectorMCP/actions/workflows/ruby.yml/badge.svg?branch=main)](https://github.com/sergiobayona/vector_mcp/actions/workflows/ruby.yml)
[![Maintainability](https://qlty.sh/badges/fdb143b3-148a-4a86-8e3b-4ccebe993528/maintainability.svg)](https://qlty.sh/gh/sergiobayona/projects/vector_mcp)
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

### Registering Prompts

Prompts are pre-defined templates or workflows that your server can offer to clients. These can guide users or LLMs in specific interactions. Use `register_prompt` with a block to define them. The server validates the `arguments` definition upon registration.

```ruby
server.register_prompt(
  name: "project_summary_generator", # Unique name (identifier) for this prompt.
  description: "Creates a concise summary for a project given its key details.",
  arguments: [ # Defines the arguments this prompt template expects.
    { name: "project_name", description: "The name of the project.", type: "string", required: true },
    { name: "project_goal", description: "The primary objective of the project.", type: "string", required: true },
    { name: "project_deadline", description: "The deadline for the project (e.g., YYYY-MM-DD).", type: "string", required: false } # 'type' can be 'string', 'number', 'boolean' etc.
  ]
) do |invocation_args, session|
  # This block is called when a client requests this prompt (e.g., via "prompts/get").
  # - invocation_args: A Hash of arguments provided by the client for this specific call,
  #                    validated against the 'arguments' definition above.
  #                    Example: { "project_name" => "Phoenix Initiative", "project_goal" => "Revitalize core systems" }
  # - session: The VectorMCP::Session object for context (client info, etc.).

  client_name = session.client_info&.dig('name') || "Valued User"
  project_name = invocation_args["project_name"]
  project_goal = invocation_args["project_goal"]
  deadline_info = invocation_args["project_deadline"] ? " by #{invocation_args["project_deadline"]}" : ""

  # The block must return a Hash conforming to the MCP GetPromptResult schema.
  # This typically includes a 'messages' array.
  # The 'description' field here describes the *result* of this prompt generation.
  # The 'template' and 'instructions' from the previous example are now combined into the message content.
  {
    description: "Generated prompt to create a project summary for '#{project_name}'. Instructions: Use a professional and concise tone.",
    messages: [
      {
        role: "user", # Or "assistant" if the server is priming the conversation
        content: {
          type: "text",
          text: "Dear #{client_name},\n\nPlease generate a summary for the project '#{project_name}'. " \
                "The main goal is '#{project_goal}'#{deadline_info}. " \
                "Focus on key deliverables and expected outcomes."
        }
      }
      # You could add more messages here to form a multi-turn conversation starter.
      # For example, an assistant message with instructions:
      # {
      #   role: "assistant",
      #   content: { type: "text", text: "Understood. I will use a professional and concise tone." }
      # }
    ]
  }
end
```

*   `name`: A `String` or `Symbol` providing the unique identifier for the prompt. This is used by clients to request the prompt.
*   `description`: A `String` offering details about the prompt's purpose or usage (this is the description of the prompt *definition*).
*   `arguments`: An `Array` of `Hash`es, where each hash defines an expected argument for the prompt template. Each argument definition hash can include:
    *   `:name` (`String` or `Symbol`, required): The name of the argument/placeholder.
    *   `:description` (`String`, optional): A description of the argument.
    *   `:required` (`Boolean`, optional, defaults to `false` if not specified): Whether the argument must be provided by the client.
    *   `:type` (`String`, optional): The expected type of the argument (e.g., "string", "number", "boolean"). This helps clients understand what kind of input is expected.
*   The block (handler) is invoked when a client requests the prompt (e.g., via the `prompts/get` MCP method). It receives:
    *   `invocation_args`: A `Hash` containing the arguments supplied by the client for that specific request, already validated against the prompt's `arguments` definition.
    *   `session`: The `VectorMCP::Session` object, allowing access to client information (`session.client_info`) or other session-specific state.
*   The block's return value **must be a Hash** that conforms to the MCP `GetPromptResult` schema (as seen in `prompts.mdc`). This hash typically includes:
    *   `messages` (`Array<Hash>`): An array of message objects, each with `role` (e.g., "user", "assistant") and `content` (which itself is a hash, commonly `{ type: "text", text: "..." }`). This forms the actual prompt or conversation starter.
    *   `description` (`String`, optional): A description for the *generated prompt result*. This can be different from the main prompt definition's description.
    The definitions of placeholders/arguments are taken from the `arguments` parameter of `register_prompt`; this block constructs the final prompt content (the `messages` array) using the values provided for those arguments.

### Working with the Session Object

The `session` object, passed to tool, resource, and prompt handler blocks, provides crucial context about the connected client and the state of the connection.

```ruby
# Example in a tool handler
server.register_tool(name: "user_info", description: "Gets client info", input_schema: {}) do |_args, session|
  if session.initialized?
    client_name = session.client_info&.dig('name') || "Unknown Client"
    client_version = session.client_info&.dig('version') || "N/A"
    client_capabilities = session.client_capabilities || {} # Hash of capabilities client declared

    # You can use this info to tailor responses or behavior
    "Hello #{client_name} v#{client_version}! Your capabilities: #{client_capabilities.inspect}"
  else
    # Should ideally not happen if handlers are called after initialization, but good for defense
    raise VectorMCP::InitializationError, "Session not yet initialized."
  end
end
```

Key `session` attributes and methods:
*   `session.initialized?`: Returns `true` if the client has successfully completed the MCP initialization handshake. Most handlers should only perform significant work if this is true.
*   `session.client_info`: A `Hash` containing information about the client (e.g., `name`, `version`), as provided in the `initialize` request.
*   `session.client_capabilities`: A `Hash` outlining the capabilities declared by the client during initialization.
*   **Storing Session-Specific State**: The `session` object itself doesn't have a built-in store for arbitrary data, but you can use its `object_id` or manage a separate hash/store keyed by session if you need to maintain state across multiple requests from the same client connection (e.g., for authentication status, user preferences loaded from a database).

### Customizing Request and Notification Handlers

While `VectorMCP` provides default handlers for standard MCP methods (like `tools/list`, `resources/read`, etc.), you can override these or add handlers for custom methods specific to your server.

Use `on_request(method_name, &block)` and `on_notification(method_name, &block)`:

```ruby
# Override the default 'ping' handler
server.on_request("ping") do |_params, _session, _server_instance|
  { message: "Custom pong!", timestamp: Time.now.iso8601 }
end

# Add a handler for a custom request
server.on_request("my_server/get_status") do |_params, session, server_instance|
  # _params: The parameters sent with the request
  # session: The VectorMCP::Session object
  # server_instance: The VectorMCP::Server instance itself
  {
    status: "All systems nominal",
    server_name: server_instance.name,
    client_name: session.client_info&.dig('name'),
    active_tools: server_instance.tools.keys
  }
end

# Add a handler for a custom notification
server.on_notification("my_server/log_event") do |params, _session, _server_instance|
  server.logger.info("Custom event logged via MCP: #{params.inspect}")
  # Notifications do not return a value to the client
end
```
*   The block for `on_request` receives `params`, `session`, and the `server` instance. It **must** return a JSON-serializable object that will form the `result` part of the JSON-RPC response.
*   The block for `on_notification` also receives `params`, `session`, and `server`. It should **not** return a value.
*   You can see the default handlers in `lib/vector_mcp/handlers/core.rb` for reference.

### Error Handling in Handlers

When writing custom handlers (for tools, resources, prompts, or custom requests), you might encounter situations where you need to signal an error to the client according to JSON-RPC and MCP conventions. `VectorMCP` provides a set_of custom error classes that map directly to MCP/JSON-RPC error codes.

If you raise an instance of these error classes (or their subclasses) from your handler, the server will catch it and automatically format a correct JSON-RPC error response.

```ruby
server.register_tool(
  name: "risky_operation",
  description: "An operation that might fail with specific errors.",
  input_schema: { type: "object", properties: { magic_word: { type: "string" } }, required: ["magic_word"] }
) do |args, session|
  unless session.client_capabilities&.dig(:experimental, :can_do_risky_stuff)
    # Example of a server-defined error, will map to a generic JSON-RPC internal error
    # unless you define a specific error code mapping.
    raise VectorMCP::ServerError.new("Client not authorized for risky operations.", code: -32000)
  end

  if args["magic_word"] != "please"
    # This is a standard MCP error type
    raise VectorMCP::InvalidParamsError.new("The magic_word parameter was incorrect.")
  end

  # ... perform operation ...
  "Risky operation successful!"
rescue VectorMCP::ProtocolError => e
  # You can catch and re-raise if needed, or let the server handle it.
  raise e
rescue StandardError => e
  # For unexpected errors, wrap them in a standard MCP error.
  # This ensures the client gets a well-formed JSON-RPC error response.
  server.logger.error("Unexpected error in risky_operation: #{e.message}")
  raise VectorMCP::InternalError.new("An unexpected error occurred during the risky operation.")
end
```

Common error classes from `vector_mcp/errors.rb` include:
*   `VectorMCP::InvalidRequestError`
*   `VectorMCP::MethodNotFoundError`
*   `VectorMCP::InvalidParamsError`
*   `VectorMCP::InternalError`
*   `VectorMCP::ServerError` (for other server-side issues, can take a custom code)
*   `VectorMCP::NotFoundError` (useful in `resources/read` or `prompts/get` if an item isn't found)

Consult `lib/vector_mcp/errors.rb` for the full list and their default MCP error codes. Using these helps maintain consistent error reporting to clients.

## Development
