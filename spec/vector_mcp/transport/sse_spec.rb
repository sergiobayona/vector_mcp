# frozen_string_literal: true

require "spec_helper"
require "rack/test" # For simulating requests
require "async/queue" # For mocking client queue
require "vector_mcp/transport/sse"
require "vector_mcp/server" # Needed for the mock server
require "vector_mcp/definitions" # Corrected require path
require "vector_mcp/session" # Needed for mock session

RSpec.describe VectorMCP::Transport::SSE do
  include Rack::Test::Methods # Include Rack::Test helpers

  let(:mock_logger) { instance_double(Logger, info: nil, debug: nil, warn: nil, error: nil, fatal: nil, :<< => nil) }
  let(:mock_server_info) { instance_double("VectorMCP::ServerInfo", name: "TestServer", version: "0.1") }
  let(:mock_resource_provider_options) { instance_double("VectorMCP::ResourceProviderOptions") }
  let(:mock_server_capabilities) { instance_double("VectorMCP::ServerCapabilities", resources: mock_resource_provider_options) }
  let(:mock_session) { instance_double(VectorMCP::Session) } # Mock session object
  let(:mock_mcp_server) do
    instance_double(
      VectorMCP::Server,
      logger: mock_logger,
      server_info: mock_server_info,
      server_capabilities: mock_server_capabilities,
      protocol_version: "2025-03-26",
      handle_message: nil # Default mock
    )
  end

  subject(:transport) { described_class.new(mock_mcp_server, options) }
  let(:options) { { path_prefix: "/test_mcp" } } # Use a specific prefix for testing

  # Helper to access the Rack app built by the transport
  let(:app) { transport.send(:build_rack_app, mock_session) }

  # Helper to access internal clients hash (use sparingly)
  let(:clients) { transport.instance_variable_get(:@clients) }

  describe "#initialize" do
    it "initializes with default host, port, and path_prefix" do
      transport_default = described_class.new(mock_mcp_server)
      expect(transport_default.server).to eq(mock_mcp_server)
      expect(transport_default.logger).to eq(mock_logger)
      expect(transport_default.host).to eq("localhost")
      expect(transport_default.port).to eq(8000)
      expect(transport_default.path_prefix).to eq("/mcp")
    end

    context "with custom options" do
      let(:options) { { host: "127.0.0.1", port: 9090, path_prefix: "/custom/api/" } }

      it "uses the provided host and port" do
        expect(transport.host).to eq("127.0.0.1")
        expect(transport.port).to eq(9090)
      end

      it "correctly formats the path_prefix" do
        expect(transport.path_prefix).to eq("/custom/api") # Ensures trailing slash is removed
      end
    end

    context "with path_prefix without leading slash" do
      let(:options) { { path_prefix: "no-slash" } }

      it "adds a leading slash to path_prefix" do
        expect(transport.path_prefix).to eq("/no-slash")
      end
    end
  end

  describe "Rack Application Routing" do
    it "responds with OK to the root path" do
      get "/"
      expect(last_response).to be_ok
      expect(last_response.body).to eq("VectorMCP Server OK")
    end

    # We won't test the full SSE connection via Rack::Test easily
    # Instead, we'll test the handle_sse_connection method directly if needed.
    # For now, just check the route exists.
    it "routes GET requests to the SSE path" do
      # Mock the handler to avoid full SSE logic in routing test
      allow(transport).to receive(:handle_sse_connection).and_return([200, {}, ["SSE OK"]])
      get "/test_mcp/sse"
      expect(last_response).to be_ok
      expect(last_response.body).to eq("SSE OK")
    end

    it "routes POST requests to the message path" do
      # Mock the handler to avoid full message logic in routing test
      allow(transport).to receive(:handle_message_post).and_return([202, {}, ["Accepted"]])
      post "/test_mcp/message"
      expect(last_response.status).to eq(202)
      expect(last_response.body).to eq("Accepted")
    end
  end

  describe "#handle_message_post" do
    let(:session_id) { "test-session-123" }
    let(:mock_client_queue) { instance_double(Async::Queue) }
    let(:mock_client_conn) { described_class::ClientConnection.new(session_id, mock_client_queue, nil) }
    let(:request_id) { 1 }
    let(:request_body) { { jsonrpc: "2.0", id: request_id, method: "test/method", params: { key: "value" } }.to_json }
    let(:headers) { { "CONTENT_TYPE" => "application/json" } }

    before do
      # Register a mock client connection before the request
      clients[session_id] = mock_client_conn
      # Prevent actual enqueuing in these tests, just verify calls
      allow(transport).to receive(:enqueue_formatted_response)
      allow(transport).to receive(:enqueue_error)
    end

    context "when receiving a valid request" do
      let(:success_result) { { result: "success data" } }

      before do
        # Stub the server's message handler to return success
        allow(mock_mcp_server).to receive(:handle_message)
          .with(JSON.parse(request_body), mock_session, session_id)
          .and_return(success_result[:result]) # Server returns just the result part
      end

      it "calls the server's handle_message" do
        post "/test_mcp/message?session_id=#{session_id}", request_body, headers
        expect(mock_mcp_server).to have_received(:handle_message)
          .with(JSON.parse(request_body), mock_session, session_id)
      end

      it "enqueues a formatted response" do
        post "/test_mcp/message?session_id=#{session_id}", request_body, headers
        expect(transport).to have_received(:enqueue_formatted_response)
          .with(mock_client_conn, request_id, success_result[:result])
      end

      it "returns a 202 Accepted response" do
        post "/test_mcp/message?session_id=#{session_id}", request_body, headers
        expect(last_response.status).to eq(202)
        expect(JSON.parse(last_response.body)).to eq({ "status" => "accepted", "id" => request_id })
      end
    end

    context "when session_id query parameter is missing" do
      it "returns a 400 Bad Request response" do
        post "/test_mcp/message", request_body, headers # No session_id in query
        expect(last_response.status).to eq(400)
        expect(JSON.parse(last_response.body)["error"]["code"]).to eq(-32_600) # Invalid Request
        expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Missing session_id parameter")
      end

      it "does not call server handle_message" do
        expect(mock_mcp_server).not_to receive(:handle_message)
        post "/test_mcp/message", request_body, headers
      end

      it "does not enqueue any response or error" do
        expect(transport).not_to receive(:enqueue_formatted_response)
        expect(transport).not_to receive(:enqueue_error)
        post "/test_mcp/message", request_body, headers
      end
    end

    context "when session_id is invalid or expired" do
      before do
        # Ensure the session_id we use is not in the clients hash
        clients.delete("invalid-session-id")
      end

      it "returns a 404 Not Found response" do
        post "/test_mcp/message?session_id=invalid-session-id", request_body, headers
        expect(last_response.status).to eq(404)
        expect(JSON.parse(last_response.body)["error"]["code"]).to eq(-32_001) # Custom server error
        expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Invalid session_id")
      end

      it "does not call server handle_message" do
        expect(mock_mcp_server).not_to receive(:handle_message)
        post "/test_mcp/message?session_id=invalid-session-id", request_body, headers
      end

      it "does not enqueue any response or error" do
        expect(transport).not_to receive(:enqueue_formatted_response)
        expect(transport).not_to receive(:enqueue_error)
        post "/test_mcp/message?session_id=invalid-session-id", request_body, headers
      end
    end

    context "when request body contains invalid JSON" do
      let(:invalid_request_body) { "{\"jsonrpc\": \"2.0\", \"id\": 2, \"method\": \"bad/json" }
      # Missing closing quote and brace

      it "returns a 400 Bad Request response" do
        post "/test_mcp/message?session_id=#{session_id}", invalid_request_body, headers
        expect(last_response.status).to eq(400)
        expect(JSON.parse(last_response.body)["error"]["code"]).to eq(-32_700) # Parse Error
        expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Parse error")
        # ID extracted from invalid JSON should be a string
        expect(JSON.parse(last_response.body)["id"]).to eq("2") # Expect string "2"
      end

      it "does not call server handle_message" do
        expect(mock_mcp_server).not_to receive(:handle_message)
        post "/test_mcp/message?session_id=#{session_id}", invalid_request_body, headers
      end

      it "enqueues a Parse Error (-32700) message" do
        # Allow the util to be called
        allow(VectorMCP::Util).to receive(:extract_id_from_invalid_json).and_return(2)
        post "/test_mcp/message?session_id=#{session_id}", invalid_request_body, headers
        expect(transport).to have_received(:enqueue_error).with(mock_client_conn, 2, -32_700, "Parse error")
      end
    end

    context "when server.handle_message raises a ProtocolError" do
      let(:protocol_error) { VectorMCP::MethodNotFoundError.new("test/method", request_id: request_id) }

      before do
        allow(mock_mcp_server).to receive(:handle_message)
          .with(JSON.parse(request_body), mock_session, session_id)
          .and_raise(protocol_error)
      end

      it "returns the corresponding HTTP status code (404 for MethodNotFound)" do
        post "/test_mcp/message?session_id=#{session_id}", request_body, headers
        expect(last_response.status).to eq(404)
      end

      it "returns the formatted JSON-RPC error in the body" do
        post "/test_mcp/message?session_id=#{session_id}", request_body, headers
        error_response = JSON.parse(last_response.body)["error"]
        expect(error_response["code"]).to eq(protocol_error.code)
        expect(error_response["message"]).to eq(protocol_error.message)
        expect(JSON.parse(last_response.body)["id"]).to eq(request_id)
      end

      it "enqueues the same error message via SSE" do
        post "/test_mcp/message?session_id=#{session_id}", request_body, headers
        expect(transport).to have_received(:enqueue_error)
          .with(mock_client_conn, request_id, protocol_error.code, protocol_error.message, protocol_error.details)
      end
    end

    context "when server.handle_message raises a StandardError" do
      let(:standard_error) { StandardError.new("Something unexpected broke") }

      before do
        allow(mock_mcp_server).to receive(:handle_message)
          .with(JSON.parse(request_body), mock_session, session_id)
          .and_raise(standard_error)
      end

      it "returns a 500 Internal Server Error response" do
        post "/test_mcp/message?session_id=#{session_id}", request_body, headers
        expect(last_response.status).to eq(500)
      end

      it "returns a generic JSON-RPC Internal Error in the body" do
        post "/test_mcp/message?session_id=#{session_id}", request_body, headers
        error_response = JSON.parse(last_response.body)["error"]
        expect(error_response["code"]).to eq(-32_603)
        expect(error_response["message"]).to eq("Internal server error")
        # We also check that the original error message is included in the 'data' field
        expect(error_response["data"]["details"]).to eq(standard_error.message)
        expect(JSON.parse(last_response.body)["id"]).to eq(request_id)
      end

      it "enqueues the Internal Error message via SSE" do
        post "/test_mcp/message?session_id=#{session_id}", request_body, headers
        expect(transport).to have_received(:enqueue_error)
          .with(mock_client_conn, request_id, -32_603, "Internal server error", { details: standard_error.message })
      end
    end

    context "when receiving a non-POST request" do
      it "returns a 405 Method Not Allowed response" do
        get "/test_mcp/message?session_id=#{session_id}" # Use GET instead of POST
        expect(last_response.status).to eq(405)
        expect(last_response.body).to eq("Method Not Allowed")
      end

      it "does not call server handle_message" do
        expect(mock_mcp_server).not_to receive(:handle_message)
        get "/test_mcp/message?session_id=#{session_id}"
      end

      it "does not enqueue any response or error" do
        expect(transport).not_to receive(:enqueue_formatted_response)
        expect(transport).not_to receive(:enqueue_error)
        get "/test_mcp/message?session_id=#{session_id}"
      end
    end
  end

  describe "#send_notification" do
    let(:session_id) { "notify-session-456" }
    let(:method) { "test/notification" }
    let(:params) { { data: "info" } }
    let(:expected_message) { { jsonrpc: "2.0", method: method, params: params } }
    let(:mock_client_queue) { instance_double(Async::Queue) }
    let(:mock_client_conn) { described_class::ClientConnection.new(session_id, mock_client_queue, nil) }

    before do
      allow(mock_client_queue).to receive(:enqueue) # Stub the actual enqueue
    end

    context "when client connection exists" do
      before do
        clients[session_id] = mock_client_conn
      end

      it "enqueues the formatted notification message to the client queue" do
        transport.send_notification(session_id, method, params)
        expect(mock_client_queue).to have_received(:enqueue).with(expected_message)
      end

      it "returns true" do
        expect(transport.send_notification(session_id, method, params)).to be true
      end
    end

    context "when client connection does not exist" do
      before do
        clients.delete(session_id)
      end

      it "does not enqueue any message" do
        expect(mock_client_queue).not_to receive(:enqueue)
        transport.send_notification(session_id, method, params)
      end

      it "returns false" do
        expect(transport.send_notification(session_id, method, params)).to be false
      end

      it "logs a warning" do
        # Expect the logger (which is mocked) to receive a warn call
        expect(mock_logger).to receive(:warn).with(/Cannot enqueue message.*#{session_id}/)
        transport.send_notification(session_id, method, params)
      end
    end
  end
end
