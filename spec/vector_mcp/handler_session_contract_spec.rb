# frozen_string_literal: true

require "spec_helper"
require "vector_mcp/server"
require "vector_mcp/transport/http_stream"

# Pins the contract between the framework and user-registered handlers, so the
# session/request refactor can prove it did not change what user code observes:
# - tool handlers receive (arguments, session) where session exposes the
#   session identity, user data store, initialization state, security context,
#   and per-request header/param access
# - resource handlers receive (params, security_context) where the second
#   argument exposes the authenticated user
RSpec.describe "Handler-facing session contract" do
  let(:server) do
    VectorMCP::Server.new(name: "ContractServer", version: "1.0.0", log_level: Logger::FATAL)
  end
  let(:transport) { VectorMCP::Transport::HttpStream.new(server, port: 0) }
  let(:manager) { transport.session_manager }
  let(:observations) { {} }

  before do
    server.enable_authentication!(strategy: :api_key, keys: %w[secret-key])

    obs = observations
    server.register_tool(
      name: "observer",
      description: "Records what the tool handler can see",
      input_schema: { type: "object", properties: {} }
    ) do |_args, session|
      obs[:session_id] = session.id
      obs[:initialized] = session.initialized?
      obs[:api_key_header] = session.request_header("X-API-Key")
      obs[:user] = session.security_context&.user
      session.data[:visited] = true
      "ok"
    end

    server.register_resource(
      uri: "memory://observer",
      name: "observer",
      description: "Records what the resource handler can see"
    ) do |_params, session_context|
      obs[:resource_authenticated] = session_context.authenticated?
      obs[:resource_user] = session_context.user
      "resource-content"
    end
  end

  def rack_env(key: "secret-key")
    {
      "REQUEST_METHOD" => "POST",
      "PATH_INFO" => "/mcp",
      "QUERY_STRING" => "",
      "HTTP_ACCEPT" => "application/json",
      "HTTP_X_API_KEY" => key
    }
  end

  def dispatch(message, session, env)
    transport.send(:handle_single_request, message, session, env)
  end

  def initialized_session(env)
    session = manager.create_session(nil, env)
    session.initialize!(
      "protocolVersion" => "2024-11-05",
      "clientInfo" => { "name" => "contract-spec" },
      "capabilities" => {}
    )
    session
  end

  it "gives tool handlers a session with identity, state, request data, and security context" do
    env = rack_env
    session = initialized_session(env)
    resolved = transport.send(:resolve_session_for_post, session.id,
                              { "method" => "tools/call" }, env)

    dispatch(
      { "jsonrpc" => "2.0", "id" => 1, "method" => "tools/call",
        "params" => { "name" => "observer", "arguments" => {} } },
      resolved, env
    )

    expect(observations[:session_id]).to eq(session.id)
    expect(observations[:initialized]).to be(true)
    expect(observations[:api_key_header]).to eq("secret-key")
    expect(observations[:user]).to eq(api_key: "secret-key")
    expect(session.data[:visited]).to be(true)
  end

  it "gives resource handlers the authenticated security context" do
    env = rack_env
    session = initialized_session(env)
    resolved = transport.send(:resolve_session_for_post, session.id,
                              { "method" => "resources/read" }, env)

    dispatch(
      { "jsonrpc" => "2.0", "id" => 2, "method" => "resources/read",
        "params" => { "uri" => "memory://observer" } },
      resolved, env
    )

    expect(observations[:resource_authenticated]).to be(true)
    expect(observations[:resource_user]).to eq(api_key: "secret-key")
  end
end
