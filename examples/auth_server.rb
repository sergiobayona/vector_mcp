#!/usr/bin/env ruby
# frozen_string_literal: true

# Authentication Example Server
# Demonstrates VectorMCP's seamless opt-in authentication and authorization features

require_relative "../lib/vector_mcp"

# Create server with default settings (no authentication)
server = VectorMCP.new(name: "AuthExampleServer", version: "1.0.0")

# Register public tools (available without authentication)
server.register_tool(
  name: "public_info",
  description: "Returns public information - no authentication required",
  input_schema: {
    type: "object",
    properties: { topic: { type: "string" } },
    required: ["topic"]
  }
) do |args, _session_context|
  "Public information about #{args["topic"]}: This is freely available data."
end

# Enable authentication with API keys
puts "🔐 Enabling authentication..."
server.enable_authentication!(
  strategy: :api_key,
  keys: %w[admin-secret-key user-read-key demo-key-123]
)

# Register protected tools (require authentication)
server.register_tool(
  name: "secure_data",
  description: "Returns sensitive data - authentication required",
  input_schema: {
    type: "object",
    properties: { data_type: { type: "string" } },
    required: ["data_type"]
  }
) do |args, session_context|
  user_id = session_context&.user_identifier || "unknown"
  "🔒 Secure data for #{args["data_type"]} accessed by user: #{user_id}"
end

# Enable authorization with fine-grained policies
puts "🛡️ Enabling authorization with policies..."
server.enable_authorization! do
  # Authorization policy for tools
  authorize_tools do |user, _action, tool|
    case tool.name
    when "public_info"
      true # Public tools are always accessible
    when "admin_tool"
      # Only admin API key can use admin tools
      user&.dig(:api_key) == "admin-secret-key"
    else
      # Default: require authentication for secure_data and other tools
      user.present?
    end
  end
end

# Register admin-only tool
server.register_tool(
  name: "admin_tool",
  description: "Administrative tool - admin key required",
  input_schema: {
    type: "object",
    properties: { command: { type: "string" } },
    required: ["command"]
  }
) do |args, session_context|
  user_id = session_context&.user_identifier || "unknown"
  "⚡ Admin command '#{args["command"]}' executed by: #{user_id}"
end

# Register a resource with authorization
server.register_resource(
  uri: "config://settings",
  name: "Application Settings",
  description: "Application configuration data"
) do |_params, session_context|
  if session_context&.authenticated?
    "Authenticated user settings for: #{session_context.user_identifier}"
  else
    "Default public settings"
  end
end

# Show security status
puts "\n📊 Security Status:"
puts "  Authentication: #{server.security_status[:authentication][:enabled] ? "Enabled" : "Disabled"}"
puts "  Authorization: #{server.security_status[:authorization][:enabled] ? "Enabled" : "Disabled"}"
puts "  Strategies: #{server.security_status[:authentication][:strategies]}"

puts "\n🚀 Starting server..."
puts "\nUsage Examples:"
puts "  Public tool (no auth): echo '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," \
     "\"params\":{\"name\":\"public_info\",\"arguments\":{\"topic\":\"weather\"}}}'"
puts "  Secure tool (needs auth): Add header 'X-API-Key: demo-key-123'"
puts "  Admin tool (admin only): Add header 'X-API-Key: admin-secret-key'"
puts "\nPress Ctrl+C to stop"

# Run the server
server.run(transport: :stdio)
