#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: HTTP Stream Transport with Sampling Support
# This demonstrates the new server-initiated request functionality in the HttpStream transport

require_relative "../../lib/vector_mcp"
require_relative "../../lib/vector_mcp/transport/http_stream"

# Create a server with sampling capabilities
server = VectorMCP::Server.new("http-stream-sampling-demo", version: "1.0.0")

# Add a tool that uses sampling to interact with the client
server.register_tool(
  name: "interactive_chat",
  description: "Starts an interactive chat session using sampling",
  input_schema: {
    type: "object",
    properties: {
      topic: {
        type: "string",
        description: "The topic to discuss"
      }
    },
    required: ["topic"]
  }
) do |args, session|
  topic = args["topic"]
  
  # Use sampling to ask the client for a response
  sampling_result = session.sample(
    messages: [
      {
        role: "user",
        content: {
          type: "text",
          text: "Let's discuss #{topic}. What are your thoughts on this topic?"
        }
      }
    ],
    system_prompt: "You are a helpful assistant engaging in conversation.",
    max_tokens: 500
  )
  
  # Extract the response
  response_content = sampling_result.content
  
  # Ask a follow-up question
  follow_up = session.sample(
    messages: [
      {
        role: "user",
        content: {
          type: "text",
          text: "Let's discuss #{topic}. What are your thoughts on this topic?"
        }
      },
      {
        role: "assistant",
        content: response_content
      },
      {
        role: "user",
        content: {
          type: "text",
          text: "That's interesting! Can you elaborate on that point?"
        }
      }
    ],
    system_prompt: "You are a helpful assistant engaging in conversation.",
    max_tokens: 300
  )
  
  {
    topic: topic,
    initial_response: response_content,
    follow_up_response: follow_up.content,
    conversation_summary: "Had a discussion about #{topic} with the client using sampling."
  }
end

# Add a simple tool that demonstrates session-specific sampling
server.register_tool(
  name: "session_info",
  description: "Gets information about the current session and tests sampling",
  input_schema: {
    type: "object",
    properties: {},
    required: []
  }
) do |args, session|
  # Use sampling to get the current time from the client
  time_result = session.sample(
    messages: [
      {
        role: "user",
        content: {
          type: "text",
          text: "What is the current date and time?"
        }
      }
    ],
    system_prompt: "Respond with the current date and time.",
    max_tokens: 100
  )
  
  {
    session_id: session.id,
    transport_type: "HttpStream",
    sampling_works: true,
    client_time_response: time_result.content
  }
end

# Start the server with HttpStream transport
puts "Starting HTTP Stream server with sampling support on http://localhost:8080/mcp"
puts "This server demonstrates:"
puts "  - Server-initiated requests (sampling)"
puts "  - Bidirectional communication over HTTP"
puts "  - Session-based request/response tracking"
puts ""
puts "To test sampling functionality:"
puts "  1. Connect a client to the streaming endpoint (GET /mcp with Mcp-Session-Id header)"
puts "  2. Call the 'interactive_chat' tool with a topic"
puts "  3. The server will send sampling requests to your client"
puts ""
puts "Press Ctrl+C to stop the server"

begin
  transport = VectorMCP::Transport::HttpStream.new(server, port: 8080)
  server.run(transport: transport)
rescue Interrupt
  puts "\nServer stopped"
end