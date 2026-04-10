# frozen_string_literal: true

require "spec_helper"
require "rack/test"
require "vector_mcp/server"
require "vector_mcp/transport/http_stream"

RSpec.describe "HttpStream OAuth 2.1 Resource Server", :oauth do
  include Rack::Test::Methods

  let(:server) { VectorMCP::Server.new(name: "OAuthTestServer", version: "1.0.0", log_level: Logger::FATAL) }
  let(:transport) { VectorMCP::Transport::HttpStream.new(server) }
  let(:app) { transport }

  let(:resource_metadata_url) { "https://example.test/.well-known/oauth-protected-resource" }
  let(:expected_www_authenticate) do
    %(Bearer realm="mcp", resource_metadata="#{resource_metadata_url}")
  end

  let(:initialize_body) do
    {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: "2025-11-25",
        capabilities: {},
        clientInfo: { name: "test-client", version: "1.0.0" }
      }
    }.to_json
  end

  let(:request_headers) do
    {
      "CONTENT_TYPE" => "application/json",
      "HTTP_ACCEPT" => "application/json, text/event-stream"
    }
  end

  before do
    server.register_tool(
      name: "whoami",
      description: "Return the authenticated user identifier",
      input_schema: { type: "object", properties: {} }
    ) do |_args, session|
      session&.security_context&.user_identifier || "anonymous"
    end
  end

  describe "when authentication is enabled with resource_metadata_url" do
    before do
      server.enable_authentication!(
        strategy: :api_key,
        keys: ["valid-key"],
        resource_metadata_url: resource_metadata_url
      )
    end

    it "returns 401 with WWW-Authenticate header for unauthenticated POST /mcp" do
      post "/mcp", initialize_body, request_headers

      expect(last_response.status).to eq(401)
      expect(last_response.headers["WWW-Authenticate"]).to eq(expected_www_authenticate)
    end

    it "returns a JSON-RPC error envelope in the 401 body" do
      post "/mcp", initialize_body, request_headers

      expect(last_response.content_type).to include("application/json")
      body = JSON.parse(last_response.body)
      expect(body["jsonrpc"]).to eq("2.0")
      expect(body["error"]["code"]).to eq(-32_401)
      expect(body["error"]["message"]).to eq("Authentication required")
    end

    it "returns 401 with WWW-Authenticate header for unauthenticated GET /mcp" do
      get "/mcp", {}, request_headers.merge("HTTP_ACCEPT" => "text/event-stream",
                                            "HTTP_MCP_SESSION_ID" => "some-session")

      expect(last_response.status).to eq(401)
      expect(last_response.headers["WWW-Authenticate"]).to eq(expected_www_authenticate)
    end

    it "returns 401 with WWW-Authenticate header for unauthenticated DELETE /mcp" do
      delete "/mcp", nil, request_headers.merge("HTTP_MCP_SESSION_ID" => "some-session")

      expect(last_response.status).to eq(401)
      expect(last_response.headers["WWW-Authenticate"]).to eq(expected_www_authenticate)
    end

    it "allows authenticated POST /mcp through with a valid bearer token" do
      post "/mcp",
           initialize_body,
           request_headers.merge("HTTP_AUTHORIZATION" => "Bearer valid-key")

      expect(last_response.status).to eq(200)
      expect(last_response.headers["Mcp-Session-Id"]).not_to be_nil
    end

    it "allows authenticated POST /mcp through with a valid X-API-Key header" do
      post "/mcp",
           initialize_body,
           request_headers.merge("HTTP_X_API_KEY" => "valid-key")

      expect(last_response.status).to eq(200)
    end

    it "leaves the unauthenticated health check endpoint accessible" do
      get "/"

      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq("VectorMCP HttpStream Server OK")
    end
  end

  describe "when authentication is enabled WITHOUT resource_metadata_url (legacy mode)" do
    before do
      server.enable_authentication!(strategy: :api_key, keys: ["valid-key"])
    end

    it "does not return HTTP 401 from the transport layer for unauthenticated initialize" do
      post "/mcp", initialize_body, request_headers

      expect(last_response.status).not_to eq(401)
      expect(last_response.headers["WWW-Authenticate"]).to be_nil
    end

    it "does not include a WWW-Authenticate header on any response" do
      post "/mcp", initialize_body, request_headers

      expect(last_response.headers.keys).not_to include("WWW-Authenticate")
    end
  end

  describe "when authentication is disabled entirely" do
    it "does not return 401 even if resource_metadata_url is meaningless" do
      post "/mcp", initialize_body, request_headers

      expect(last_response.status).not_to eq(401)
    end
  end

  # These tests exercise the primary documented Rails + Doorkeeper integration path:
  # strategy: :custom, where the user's handler reads `request[:headers]["Authorization"]`.
  # The custom strategy does NOT have a raw-Rack-env fallback, so the transport gate
  # MUST normalize the request before calling the strategy.
  describe "when authentication is enabled with :custom strategy and resource_metadata_url" do
    let(:valid_token) { "valid-oauth-token" }
    let(:captured_requests) { [] }

    before do
      captured = captured_requests # close over local for block
      server.enable_authentication!(
        strategy: :custom,
        resource_metadata_url: resource_metadata_url
      ) do |request|
        captured << request
        header = request[:headers]["Authorization"]
        next false unless header&.start_with?("Bearer ")

        token = header.sub(/\ABearer /, "").strip
        next false unless token == valid_token

        { user_id: 42, email: "alice@example.test" }
      end
    end

    it "allows authenticated POST /mcp through with a valid bearer token" do
      post "/mcp",
           initialize_body,
           request_headers.merge("HTTP_AUTHORIZATION" => "Bearer #{valid_token}")

      expect(last_response.status).to eq(200)
      expect(last_response.headers["Mcp-Session-Id"]).not_to be_nil
    end

    it "returns 401 with WWW-Authenticate for an invalid bearer token" do
      post "/mcp",
           initialize_body,
           request_headers.merge("HTTP_AUTHORIZATION" => "Bearer wrong-token")

      expect(last_response.status).to eq(401)
      expect(last_response.headers["WWW-Authenticate"]).to eq(expected_www_authenticate)
    end

    it "passes a normalized request hash (not a raw Rack env) to the custom handler" do
      post "/mcp",
           initialize_body,
           request_headers.merge("HTTP_AUTHORIZATION" => "Bearer #{valid_token}")

      expect(captured_requests).not_to be_empty
      received = captured_requests.first

      expect(received).to be_a(Hash)
      expect(received).to have_key(:headers)
      expect(received[:headers]).to be_a(Hash)
      expect(received[:headers]["Authorization"]).to eq("Bearer #{valid_token}")
      # A raw Rack env would have "REQUEST_METHOD" as a top-level string key.
      # A normalized request does not.
      expect(received).not_to have_key("REQUEST_METHOD")
    end
  end

  describe "when the custom auth handler raises an exception" do
    # The Custom strategy already swallows handler exceptions and returns false,
    # so a raising handler still produces a 401 via the normal "unauthenticated"
    # path. That's still worth asserting — if someone later removes Custom's
    # rescue, the transport must not leak a 500.
    before do
      server.enable_authentication!(
        strategy: :custom,
        resource_metadata_url: resource_metadata_url
      ) do |_request|
        raise "boom: simulated handler failure"
      end
    end

    it "treats the failure as unauthenticated and returns 401, not 500" do
      post "/mcp",
           initialize_body,
           request_headers.merge("HTTP_AUTHORIZATION" => "Bearer anything")

      expect(last_response.status).to eq(401)
      expect(last_response.headers["WWW-Authenticate"]).to eq(expected_www_authenticate)
    end

    it "does not let the exception propagate to the Rack caller" do
      expect do
        post "/mcp",
             initialize_body,
             request_headers.merge("HTTP_AUTHORIZATION" => "Bearer anything")
      end.not_to raise_error
    end
  end

  # The transport gate has its own +rescue StandardError+ as a defense-in-depth
  # safety net around +security_middleware.authenticate_request+. Strategies
  # typically swallow their own errors, but if the middleware layer itself
  # raises (e.g. due to a normalization bug or a logic error in a future
  # strategy that does not wrap its own exceptions), the transport must still
  # produce a 401 with the OAuth WWW-Authenticate header rather than a 500.
  # This block exercises that rescue directly by stubbing the middleware to raise.
  describe "when security_middleware.authenticate_request raises" do
    let(:security_logger_spy) { instance_spy("VectorMCP::Logger") }

    before do
      allow(VectorMCP).to receive(:logger_for).and_call_original
      allow(VectorMCP).to receive(:logger_for).with("security").and_return(security_logger_spy)

      server.enable_authentication!(
        strategy: :api_key,
        keys: ["valid-key"],
        resource_metadata_url: resource_metadata_url
      )

      allow(server.security_middleware).to receive(:authenticate_request)
        .and_raise(StandardError, "middleware exploded")
    end

    it "returns 401 with the OAuth WWW-Authenticate header, not 500" do
      post "/mcp",
           initialize_body,
           request_headers.merge("HTTP_AUTHORIZATION" => "Bearer valid-key")

      expect(last_response.status).to eq(401)
      expect(last_response.headers["WWW-Authenticate"]).to eq(expected_www_authenticate)
    end

    it "does not let the exception propagate to the Rack caller" do
      expect do
        post "/mcp",
             initialize_body,
             request_headers.merge("HTTP_AUTHORIZATION" => "Bearer valid-key")
      end.not_to raise_error
    end

    it "logs a security warning that names the raised error class and message" do
      post "/mcp",
           initialize_body,
           request_headers.merge("HTTP_AUTHORIZATION" => "Bearer valid-key")

      expect(security_logger_spy).to have_received(:warn) do |&block|
        message = block.call
        expect(message).to include("StandardError")
        expect(message).to include("middleware exploded")
      end
    end
  end

  describe "audit logging of 401 challenges" do
    let(:security_logger_spy) { instance_spy("VectorMCP::Logger") }

    before do
      allow(VectorMCP).to receive(:logger_for).and_call_original
      allow(VectorMCP).to receive(:logger_for).with("security").and_return(security_logger_spy)

      server.enable_authentication!(
        strategy: :api_key,
        keys: ["valid-key"],
        resource_metadata_url: resource_metadata_url
      )
    end

    it "emits an info-level audit log for each OAuth 401 challenge" do
      post "/mcp", initialize_body, request_headers

      expect(last_response.status).to eq(401)
      expect(security_logger_spy).to have_received(:info) do |&block|
        message = block.call
        expect(message).to include("OAuth 401 challenge")
        expect(message).to include("POST")
        expect(message).to include("/mcp")
      end
    end

    it "does not log a 401 audit entry when the request is authenticated" do
      post "/mcp",
           initialize_body,
           request_headers.merge("HTTP_AUTHORIZATION" => "Bearer valid-key")

      expect(last_response.status).to eq(200)
      expect(security_logger_spy).not_to have_received(:info)
    end
  end

  describe "disable_authentication! lifecycle" do
    it "stops emitting 401 challenges at the transport layer after disable" do
      server.enable_authentication!(
        strategy: :api_key,
        keys: ["valid-key"],
        resource_metadata_url: resource_metadata_url
      )

      post "/mcp", initialize_body, request_headers
      expect(last_response.status).to eq(401)

      server.disable_authentication!

      post "/mcp", initialize_body, request_headers
      expect(last_response.status).not_to eq(401)
      expect(last_response.headers["WWW-Authenticate"]).to be_nil
    end
  end
end
