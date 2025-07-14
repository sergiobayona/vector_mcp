# frozen_string_literal: true

require "spec_helper"
require "rack/test"
require "vector_mcp/transport/sse"
require "vector_mcp/server"
require "vector_mcp/definitions"
require "vector_mcp/session"

RSpec.describe VectorMCP::Transport::SSE do
  include Rack::Test::Methods

  let(:mock_logger) { instance_double(Logger, info: nil, debug: nil, warn: nil, error: nil, fatal: nil) }
  let(:mock_server_info) { instance_double("VectorMCP::ServerInfo", name: "TestServer", version: "0.1") }
  let(:mock_resource_provider_options) { instance_double("VectorMCP::ResourceProviderOptions") }
  let(:mock_server_capabilities) { instance_double("VectorMCP::ServerCapabilities", resources: mock_resource_provider_options) }
  let(:mock_session) { instance_double(VectorMCP::Session) }
  let(:mock_mcp_server) do
    instance_double(
      VectorMCP::Server,
      logger: mock_logger,
      server_info: mock_server_info,
      server_capabilities: mock_server_capabilities,
      protocol_version: "2024-11-05",
      handle_message: nil,
      security_middleware: nil
    )
  end

  subject(:transport) { described_class.new(mock_mcp_server, options) }
  let(:options) { { path_prefix: "/test_mcp" } }

  # Helper to access the Rack app built by the transport
  let(:app) { transport.build_rack_app(mock_session) }

  # Helper to access internal clients hash
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
        expect(transport.path_prefix).to eq("/custom/api")
      end
    end

    context "with path_prefix without leading slash" do
      let(:options) { { path_prefix: "no-slash" } }

      it "adds a leading slash to path_prefix" do
        expect(transport.path_prefix).to eq("/no-slash")
      end
    end

    it "initializes with thread-safe client storage" do
      expect(clients).to be_a(Concurrent::Hash)
      expect(clients).to be_empty
    end

    it "logs the initialization" do
      expect(mock_logger).to receive(:debug).with(no_args)
      described_class.new(mock_mcp_server, options)
    end
  end

  describe "Rack Application Routing" do
    it "responds with OK to the root path" do
      get "/"
      expect(last_response).to be_ok
      expect(last_response.body).to eq("VectorMCP Server OK")
    end

    it "routes GET requests to the SSE path" do
      # Mock the SSE connection handler to avoid full SSE logic
      allow(transport).to receive(:handle_sse_connection).and_return([200, {}, ["SSE OK"]])
      get "/test_mcp/sse"
      expect(last_response).to be_ok
      expect(last_response.body).to eq("SSE OK")
    end

    it "routes POST requests to the message path" do
      # Mock the message handler to avoid full message logic
      allow(transport).to receive(:handle_message_post).and_return([202, {}, ["Accepted"]])
      post "/test_mcp/message"
      expect(last_response.status).to eq(202)
      expect(last_response.body).to eq("Accepted")
    end

    it "returns 404 for unknown paths" do
      get "/unknown/path"
      expect(last_response.status).to eq(404)
      expect(last_response.body).to eq("Not Found")
    end
  end

  describe "#send_notification" do
    let(:method_name) { "test/notification" }
    let(:params) { { key: "value" } }
    let(:mock_client_conn) { instance_double(VectorMCP::Transport::SSE::ClientConnection, session_id: "test-session-123") }

    context "when clients are available" do
      before do
        clients["test-session-123"] = mock_client_conn
        allow(VectorMCP::Transport::SSE::StreamManager).to receive(:enqueue_message).and_return(true)
      end

      it "enqueues the notification to first available client" do
        expected_message = { jsonrpc: "2.0", method: method_name, params: params }
        expect(VectorMCP::Transport::SSE::StreamManager).to receive(:enqueue_message).with(mock_client_conn, expected_message)

        result = transport.send_notification(method_name, params)
        expect(result).to be true
      end

      it "works without params" do
        expected_message = { jsonrpc: "2.0", method: method_name }
        expect(VectorMCP::Transport::SSE::StreamManager).to receive(:enqueue_message).with(mock_client_conn, expected_message)

        result = transport.send_notification(method_name)
        expect(result).to be true
      end
    end

    context "when no clients are available" do
      it "returns false" do
        result = transport.send_notification(method_name, params)
        expect(result).to be false
      end
    end
  end

  describe "#send_notification_to_session" do
    let(:session_id) { "test-session-123" }
    let(:method_name) { "test/notification" }
    let(:params) { { key: "value" } }
    let(:mock_client_conn) { instance_double(VectorMCP::Transport::SSE::ClientConnection, session_id: session_id) }

    context "when client exists" do
      before do
        clients[session_id] = mock_client_conn
        allow(VectorMCP::Transport::SSE::StreamManager).to receive(:enqueue_message).and_return(true)
      end

      it "enqueues the notification via StreamManager" do
        expected_message = { jsonrpc: "2.0", method: method_name, params: params }
        expect(VectorMCP::Transport::SSE::StreamManager).to receive(:enqueue_message).with(mock_client_conn, expected_message)

        result = transport.send_notification_to_session(session_id, method_name, params)
        expect(result).to be true
      end

      it "works without params" do
        expected_message = { jsonrpc: "2.0", method: method_name }
        expect(VectorMCP::Transport::SSE::StreamManager).to receive(:enqueue_message).with(mock_client_conn, expected_message)

        result = transport.send_notification_to_session(session_id, method_name)
        expect(result).to be true
      end
    end

    context "when client does not exist" do
      it "returns false" do
        result = transport.send_notification_to_session("nonexistent", method_name, params)
        expect(result).to be false
      end
    end
  end

  describe "#broadcast_notification" do
    let(:method_name) { "broadcast/notification" }
    let(:params) { { broadcast: true } }
    let(:client1) { instance_double(VectorMCP::Transport::SSE::ClientConnection, session_id: "client1") }
    let(:client2) { instance_double(VectorMCP::Transport::SSE::ClientConnection, session_id: "client2") }

    before do
      clients["client1"] = client1
      clients["client2"] = client2
      allow(VectorMCP::Transport::SSE::StreamManager).to receive(:enqueue_message).and_return(true)
    end

    it "sends notification to all connected clients" do
      expected_message = { jsonrpc: "2.0", method: method_name, params: params }

      expect(VectorMCP::Transport::SSE::StreamManager).to receive(:enqueue_message).with(client1, expected_message)
      expect(VectorMCP::Transport::SSE::StreamManager).to receive(:enqueue_message).with(client2, expected_message)

      transport.broadcast_notification(method_name, params)
    end

    it "logs the broadcast" do
      expect(mock_logger).to receive(:debug).with(no_args)
      transport.broadcast_notification(method_name, params)
    end

    it "works with no clients" do
      clients.clear
      expect { transport.broadcast_notification(method_name, params) }.not_to raise_error
    end
  end

  describe "#handle_sse_connection" do
    let(:env) { { "REQUEST_METHOD" => "GET" } }

    before do
      allow(SecureRandom).to receive(:uuid).and_return("mock-session-id")
      allow(VectorMCP::Transport::SSE::ClientConnection).to receive(:new).and_return(mock_client_connection)
      allow(VectorMCP::Transport::SSE::StreamManager).to receive(:create_sse_stream).and_return(["SSE Stream"])
    end

    let(:mock_client_connection) do
      instance_double(VectorMCP::Transport::SSE::ClientConnection, session_id: "mock-session-id")
    end

    it "accepts GET requests" do
      status, headers, body = transport.send(:handle_sse_connection, env)
      expect(status).to eq(200)
      expect(headers["Content-Type"]).to eq("text/event-stream")
      expect(headers["Cache-Control"]).to eq("no-cache")
      expect(headers["Connection"]).to eq("keep-alive")
      expect(body).to eq(["SSE Stream"])
    end

    it "creates a new client connection" do
      expect(VectorMCP::Transport::SSE::ClientConnection).to receive(:new).with("mock-session-id", mock_logger)
      transport.send(:handle_sse_connection, env)
    end

    it "stores the client connection" do
      transport.send(:handle_sse_connection, env)
      expect(clients["mock-session-id"]).to eq(mock_client_connection)
    end

    it "creates SSE stream via StreamManager" do
      expect(VectorMCP::Transport::SSE::StreamManager).to receive(:create_sse_stream).with(
        mock_client_connection,
        "/test_mcp/message?session_id=mock-session-id",
        mock_logger
      )
      transport.send(:handle_sse_connection, env)
    end

    it "logs the new connection" do
      expect(mock_logger).to receive(:info).with("New SSE client connected: mock-session-id")
      expect(mock_logger).to receive(:debug).with("Client mock-session-id should POST messages to: /test_mcp/message?session_id=mock-session-id")
      transport.send(:handle_sse_connection, env)
    end

    context "with non-GET request" do
      let(:env) { { "REQUEST_METHOD" => "POST" } }

      it "returns 405 Method Not Allowed" do
        status, headers, body = transport.send(:handle_sse_connection, env)
        expect(status).to eq(405)
        expect(headers["Allow"]).to eq("GET")
        expect(body).to eq(["Method Not Allowed. Only GET is supported for SSE endpoint."])
      end

      it "logs the invalid method" do
        expect(mock_logger).to receive(:warn).with("Received non-GET request on SSE endpoint: POST")
        transport.send(:handle_sse_connection, env)
      end
    end
  end

  describe "#handle_message_post" do
    let(:session_id) { "test-session-456" }
    let(:client_conn) { instance_double(VectorMCP::Transport::SSE::ClientConnection, session_id: session_id) }
    let(:env) { { "REQUEST_METHOD" => "POST", "QUERY_STRING" => "session_id=#{session_id}" } }
    let(:mock_message_handler) { instance_double(VectorMCP::Transport::SSE::MessageHandler) }

    before do
      clients[session_id] = client_conn
      allow(VectorMCP::Transport::SSE::MessageHandler).to receive(:new).and_return(mock_message_handler)
      allow(mock_message_handler).to receive(:handle_post_message).and_return([202, {}, ["Accepted"]])
    end

    it "accepts POST requests with valid session_id" do
      status, = transport.send(:handle_message_post, env)
      expect(status).to eq(202)
    end

    it "creates MessageHandler with correct parameters" do
      # Ensure @session is set so the expectation matches the actual call
      transport.build_rack_app(mock_session)
      expect(VectorMCP::Transport::SSE::MessageHandler).to receive(:new).with(mock_mcp_server, mock_session, mock_logger)
      transport.send(:handle_message_post, env)
    end

    it "delegates to MessageHandler" do
      expect(mock_message_handler).to receive(:handle_post_message).with(env, client_conn)
      transport.send(:handle_message_post, env)
    end

    context "with non-POST request" do
      let(:env) { { "REQUEST_METHOD" => "GET", "QUERY_STRING" => "session_id=#{session_id}" } }

      it "returns 405 Method Not Allowed" do
        status, headers, body = transport.send(:handle_message_post, env)
        expect(status).to eq(405)
        expect(headers["Allow"]).to eq("POST")
        expect(body).to eq(["Method Not Allowed"])
      end

      it "logs the invalid method" do
        expect(mock_logger).to receive(:warn).with("Received non-POST request on message endpoint: GET")
        transport.send(:handle_message_post, env)
      end
    end

    context "without session_id parameter" do
      let(:env) { { "REQUEST_METHOD" => "POST", "QUERY_STRING" => "" } }

      it "returns 400 Bad Request" do
        status, = transport.send(:handle_message_post, env)
        expect(status).to eq(400)
      end

      it "returns JSON-RPC error" do
        _, _, body = transport.send(:handle_message_post, env)
        response = JSON.parse(body.first)
        expect(response["error"]["code"]).to eq(VectorMCP::InvalidRequestError.new("Missing session_id parameter").code)
        expect(response["error"]["message"]).to eq("Missing session_id parameter")
      end
    end

    context "with invalid session_id" do
      let(:env) { { "REQUEST_METHOD" => "POST", "QUERY_STRING" => "session_id=invalid" } }

      it "returns 404 Not Found" do
        status, = transport.send(:handle_message_post, env)
        expect(status).to eq(404)
      end

      it "returns JSON-RPC error" do
        _, _, body = transport.send(:handle_message_post, env)
        response = JSON.parse(body.first)
        expect(response["error"]["code"]).to eq(VectorMCP::NotFoundError.new("Invalid session_id").code)
        expect(response["error"]["message"]).to eq("Invalid session_id")
      end
    end
  end

  describe "#stop" do
    let(:client1) { instance_double(VectorMCP::Transport::SSE::ClientConnection, close: nil) }
    let(:client2) { instance_double(VectorMCP::Transport::SSE::ClientConnection, close: nil) }
    let(:mock_puma_server) { instance_double(Puma::Server, stop: nil) }

    before do
      clients["client1"] = client1
      clients["client2"] = client2
      transport.instance_variable_set(:@puma_server, mock_puma_server)
    end

    it "stops the running flag" do
      transport.stop
      expect(transport.instance_variable_get(:@running)).to be false
    end

    it "closes all client connections" do
      expect(client1).to receive(:close)
      expect(client2).to receive(:close)
      transport.stop
    end

    it "clears the clients hash" do
      transport.stop
      expect(clients).to be_empty
    end

    it "stops the Puma server" do
      expect(mock_puma_server).to receive(:stop)
      transport.stop
    end

    it "logs the shutdown" do
      expect(mock_logger).to receive(:info).with("Cleaning up 2 client connection(s)")
      expect(mock_logger).to receive(:info).with("SSE transport stopped")
      transport.stop
    end

    it "handles nil Puma server gracefully" do
      transport.instance_variable_set(:@puma_server, nil)
      expect { transport.stop }.not_to raise_error
    end
  end

  describe "#build_rack_app" do
    it "returns self as Rack app" do
      result = transport.build_rack_app
      expect(result).to eq(transport)
    end

    it "sets session when provided" do
      custom_session = instance_double(VectorMCP::Session)
      transport.build_rack_app(custom_session)
      expect(transport.instance_variable_get(:@session)).to eq(custom_session)
    end
  end

  describe "error handling in #call" do
    let(:env) { { "PATH_INFO" => "/test", "REQUEST_METHOD" => "GET" } }

    before do
      allow(transport).to receive(:route_request).and_raise(StandardError, "Test error")
    end

    it "catches errors and returns 500" do
      status, headers, body = transport.call(env)
      expect(status).to eq(500)
      expect(headers["Content-Type"]).to eq("text/plain")
      expect(body).to eq(["Internal Server Error"])
    end

    it "logs the error" do
      expect(mock_logger).to receive(:error).with(a_string_matching(/Test error/))
      transport.call(env)
    end
  end

  describe "session creation" do
    it "creates session with server and transport" do
      expect(VectorMCP::Session).to receive(:new).with(
        mock_mcp_server,
        transport,
        hash_including(id: a_string_matching(/\A[0-9a-f-]{36}\z/))
      ).and_return(mock_session)

      transport.send(:create_session)
      expect(transport.instance_variable_get(:@session)).to eq(mock_session)
    end
  end

  describe "helper methods" do
    describe "#extract_session_id" do
      it "extracts session_id from query string" do
        result = transport.send(:extract_session_id, "session_id=abc123&other=param")
        expect(result).to eq("abc123")
      end

      it "returns nil for empty query string" do
        result = transport.send(:extract_session_id, "")
        expect(result).to be_nil
      end

      it "returns nil for nil query string" do
        result = transport.send(:extract_session_id, nil)
        expect(result).to be_nil
      end

      it "handles URL-encoded session IDs" do
        result = transport.send(:extract_session_id, "session_id=abc%2D123")
        expect(result).to eq("abc-123")
      end
    end

    describe "#build_post_url" do
      it "builds correct POST URL with session_id" do
        result = transport.send(:build_post_url, "test-session")
        expect(result).to eq("/test_mcp/message?session_id=test-session")
      end
    end
  end
end
