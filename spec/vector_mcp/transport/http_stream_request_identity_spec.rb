# frozen_string_literal: true

require "spec_helper"
require "vector_mcp/server"
require "vector_mcp/transport/http_stream"

# Characterizes the per-request identity guarantee of the HTTP Stream transport:
# a POST must be authenticated against the headers *it* arrived with, even when
# another POST on the same session is resolved between this request's session
# resolution and its dispatch. This drives the two production seams that
# `handle_post_request` calls in sequence (`resolve_session_for_post`, then
# `handle_single_request`) with the adversarial interleaving that concurrent
# POSTs can produce under Puma's thread pool.
RSpec.describe "HttpStream per-request identity isolation" do
  let(:server) do
    VectorMCP::Server.new(name: "RaceTestServer", version: "1.0.0", log_level: Logger::FATAL)
  end
  let(:transport) { VectorMCP::Transport::HttpStream.new(server, port: 0) }
  let(:manager) { transport.session_manager }
  let(:observed_keys) { [] }

  before do
    server.enable_authentication!(strategy: :api_key, keys: %w[key-a key-b])

    captured = observed_keys
    server.register_tool(
      name: "whoami",
      description: "Captures the API key the request was authenticated with",
      input_schema: { type: "object", properties: {} }
    ) do |_args, session|
      captured << session.security_context&.user&.dig(:api_key)
      "ok"
    end
  end

  def rack_env_with_key(key)
    {
      "REQUEST_METHOD" => "POST",
      "PATH_INFO" => "/mcp",
      "QUERY_STRING" => "",
      "HTTP_ACCEPT" => "application/json",
      "HTTP_X_API_KEY" => key
    }
  end

  def tool_call_message(id)
    {
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => { "name" => "whoami", "arguments" => {} }
    }
  end

  it "authenticates each POST against its own headers when another request interleaves" do
    session = manager.create_session(nil, rack_env_with_key("key-a"))
    session.context.initialize!(
      "protocolVersion" => "2024-11-05",
      "clientInfo" => { "name" => "race-spec" },
      "capabilities" => {}
    )

    env_a = rack_env_with_key("key-a")
    env_b = rack_env_with_key("key-b")
    msg_a = tool_call_message(1)
    msg_b = tool_call_message(2)

    resolved_a = transport.send(:resolve_session_for_post, session.id, msg_a, env_a)

    # Request B arrives on the same session and is resolved before request A's
    # message is dispatched — a legal interleaving under concurrent POSTs.
    transport.send(:resolve_session_for_post, session.id, msg_b, env_b)

    transport.send(:handle_single_request, msg_a, resolved_a, env_a)

    expect(observed_keys).to eq(["key-a"])
  end
end
