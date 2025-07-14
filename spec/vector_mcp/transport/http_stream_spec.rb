# frozen_string_literal: true

require "spec_helper"
require "rack/test"
require "vector_mcp/transport/http_stream"
require "vector_mcp/server"
require "vector_mcp/definitions"
require "vector_mcp/session"

RSpec.describe VectorMCP::Transport::HttpStream do
  include Rack::Test::Methods

  let(:mock_logger) { instance_double(Logger, info: nil, debug: nil, warn: nil, error: nil, fatal: nil) }
  let(:mock_server_info) { instance_double("VectorMCP::ServerInfo", name: "TestServer", version: "0.1") }
  let(:mock_resource_provider_options) { instance_double("VectorMCP::ResourceProviderOptions") }
  let(:mock_server_capabilities) { instance_double("VectorMCP::ServerCapabilities", resources: mock_resource_provider_options) }
  let(:mock_session_context) { instance_double(VectorMCP::Session, id: "test-session-123") }
  let(:mock_session) { VectorMCP::Transport::HttpStream::SessionManager::Session.new("test-session-123", mock_session_context, Time.now, Time.now, nil) }
  let(:mock_mcp_server) do
    instance_double(
      VectorMCP::Server,
      logger: mock_logger,
      server_info: mock_server_info,
      server_capabilities: mock_server_capabilities,
      protocol_version: "2024-11-05",
      handle_message: { "jsonrpc" => "2.0", "id" => 1, "result" => "success" },
      security_middleware: nil
    )
  end

  subject(:transport) { described_class.new(mock_mcp_server, options) }
  let(:options) { {} }

  # Helper to access the Rack app (the transport itself implements call)
  let(:app) { transport }

  describe "#initialize" do
    it "initializes with default configuration" do
      expect(transport.server).to eq(mock_mcp_server)
      expect(transport.logger).to eq(mock_logger)
      expect(transport.host).to eq("localhost")
      expect(transport.port).to eq(8000)
      expect(transport.path_prefix).to eq("/mcp")
    end

    context "with custom options" do
      let(:options) { { host: "127.0.0.1", port: 9090, path_prefix: "/custom/api", session_timeout: 600, event_retention: 200 } }

      it "uses provided configuration options" do
        expect(transport.host).to eq("127.0.0.1")
        expect(transport.port).to eq(9090)
        expect(transport.path_prefix).to eq("/custom/api")
      end

      it "initializes components with custom options" do
        expect(transport.session_manager).to be_a(VectorMCP::Transport::HttpStream::SessionManager)
        expect(transport.event_store).to be_a(VectorMCP::Transport::HttpStream::EventStore)
        expect(transport.stream_handler).to be_a(VectorMCP::Transport::HttpStream::StreamHandler)
      end
    end

    context "with path prefix normalization" do
      [
        ["custom", "/custom"],
        ["/custom", "/custom"],
        ["custom/", "/custom"],
        ["/custom/", "/custom"],
        ["", "/"],
        ["/", "/"]
      ].each do |input, expected|
        it "normalizes '#{input}' to '#{expected}'" do
          transport_with_prefix = described_class.new(mock_mcp_server, path_prefix: input)
          expect(transport_with_prefix.path_prefix).to eq(expected)
        end
      end
    end

    it "logs initialization" do
      expect(mock_logger).to receive(:info)
      described_class.new(mock_mcp_server)
    end
  end

  describe "#call (Rack interface)" do
    let(:start_time) { Time.now }

    before do
      allow(Time).to receive(:now).and_return(start_time, start_time + 0.1)
    end

    it "processes requests and logs completion" do
      expect(mock_logger).to receive(:debug) # debug logs during request processing
      expect(mock_logger).to receive(:info)  # info logs for request completion

      get "/"
      expect(last_response.status).to eq(200)
    end

    it "handles request errors gracefully" do
      allow(transport).to receive(:route_request).and_raise(StandardError.new("Test error"))
      expect(mock_logger).to receive(:error) { |&block| expect(block.call).to include("Request processing error") }

      get "/test"
      expect(last_response.status).to eq(500)
      expect(last_response.body).to eq("Internal Server Error")
    end
  end

  describe "request routing" do
    describe "health check endpoint" do
      it "responds to root path with health check" do
        get "/"
        expect(last_response.status).to eq(200)
        expect(last_response.content_type).to eq("text/plain")
        expect(last_response.body).to eq("VectorMCP HttpStream Server OK")
      end
    end

    describe "unknown paths" do
      it "returns 404 for unknown paths" do
        get "/unknown"
        expect(last_response.status).to eq(404)
        expect(last_response.body).to eq("Not Found")
      end
    end

    describe "MCP endpoint routing" do
      let(:session_id) { "test-session-123" }
      let(:valid_headers) { { "HTTP_MCP_SESSION_ID" => session_id } }

      before do
        # Mock session manager to return a session
        allow(transport.session_manager).to receive(:get_or_create_session).with(session_id).and_return(mock_session)
        allow(transport.session_manager).to receive(:get_session).with(session_id).and_return(mock_session)
        allow(transport.session_manager).to receive(:terminate_session).with(session_id).and_return(true)
      end

      describe "POST requests" do
        let(:json_request) { { "jsonrpc" => "2.0", "id" => 1, "method" => "ping" } }

        it "handles valid JSON-RPC requests" do
          post "/mcp", json_request.to_json, valid_headers.merge("CONTENT_TYPE" => "application/json")

          expect(last_response.status).to eq(200)
          expect(last_response.content_type).to eq("application/json")
          expect(last_response.headers["Mcp-Session-Id"]).to eq(session_id)

          response_data = JSON.parse(last_response.body)
          expect(response_data["result"]).to eq("success")
        end

        it "handles JSON parse errors" do
          post "/mcp", "invalid json", valid_headers.merge("CONTENT_TYPE" => "application/json")

          expect(last_response.status).to eq(400)
          response_data = JSON.parse(last_response.body)
          expect(response_data["error"]["code"]).to eq(-32_700)
          expect(response_data["error"]["message"]).to eq("Parse error")
        end

        it "handles protocol errors from server" do
          protocol_error = VectorMCP::MethodNotFoundError.new("unknown_method", request_id: 1)
          allow(mock_mcp_server).to receive(:handle_message).and_raise(protocol_error)

          post "/mcp", json_request.to_json, valid_headers.merge("CONTENT_TYPE" => "application/json")

          expect(last_response.status).to eq(400)
          response_data = JSON.parse(last_response.body)
          expect(response_data["error"]["code"]).to eq(-32_601)
          expect(response_data["error"]["message"]).to eq("Method not found: unknown_method")
        end

        it "creates session when no session ID provided" do
          allow(transport.session_manager).to receive(:get_or_create_session).with(nil).and_return(mock_session)

          post "/mcp", json_request.to_json, "CONTENT_TYPE" => "application/json"

          expect(last_response.status).to eq(200)
          expect(last_response.headers["Mcp-Session-Id"]).to eq(session_id)
        end
      end

      describe "GET requests (SSE streaming)" do
        it "requires Mcp-Session-Id header" do
          get "/mcp"

          expect(last_response.status).to eq(400)
          expect(last_response.body).to eq("Missing Mcp-Session-Id header")
        end

        it "returns 404 for non-existent sessions" do
          allow(transport.session_manager).to receive(:get_session).with(session_id).and_return(nil)

          get "/mcp", {}, valid_headers

          expect(last_response.status).to eq(404)
        end

        it "delegates to stream handler for valid sessions" do
          expect(transport.stream_handler).to receive(:handle_streaming_request).and_return([200, {}, []])

          get "/mcp", {}, valid_headers

          expect(last_response.status).to eq(200)
        end
      end

      describe "DELETE requests (session termination)" do
        it "requires Mcp-Session-Id header" do
          delete "/mcp"

          expect(last_response.status).to eq(400)
          expect(last_response.body).to eq("Missing Mcp-Session-Id header")
        end

        it "terminates existing sessions" do
          delete "/mcp", {}, valid_headers

          expect(last_response.status).to eq(204)
          expect(last_response.body).to be_empty
        end

        it "returns 404 for non-existent sessions" do
          allow(transport.session_manager).to receive(:terminate_session).with(session_id).and_return(false)

          delete "/mcp", {}, valid_headers

          expect(last_response.status).to eq(404)
        end
      end

      describe "unsupported HTTP methods" do
        it "returns 405 Method Not Allowed" do
          put "/mcp", {}, valid_headers

          expect(last_response.status).to eq(405)
          expect(last_response.headers["Allow"]).to eq("POST, GET, DELETE")
          expect(last_response.body).to eq("Method Not Allowed")
        end
      end
    end
  end

  describe "session management integration" do
    let(:session_id) { "test-session-456" }
    let(:mock_new_session_context) { instance_double(VectorMCP::Session, id: session_id) }
    let(:mock_new_session) { VectorMCP::Transport::HttpStream::SessionManager::Session.new(session_id, mock_new_session_context, Time.now, Time.now, nil) }

    before do
      allow(transport.session_manager).to receive(:get_or_create_session).and_return(mock_new_session)
    end

    it "integrates with session manager for POST requests" do
      expect(transport.session_manager).to receive(:get_or_create_session).with(session_id)

      post "/mcp", { "jsonrpc" => "2.0", "method" => "ping" }.to_json,
           "HTTP_MCP_SESSION_ID" => session_id, "CONTENT_TYPE" => "application/json"

      expect(last_response.headers["Mcp-Session-Id"]).to eq(session_id)
    end
  end

  describe "notification methods" do
    let(:session_id) { "test-session-789" }
    let(:method_name) { "progress" }
    let(:params) { { "message" => "Processing..." } }

    before do
      allow(transport.session_manager).to receive(:get_session).with(session_id).and_return(mock_session)
      allow(transport.stream_handler).to receive(:send_message_to_session).and_return(true)
    end

    describe "#send_notification" do
      it "sends notification to first available session" do
        expect(transport.session_manager).to receive(:active_session_ids).and_return([session_id])
        expect(transport.stream_handler).to receive(:send_message_to_session).with(
          mock_session,
          hash_including(jsonrpc: "2.0", method: method_name, params: params)
        )

        result = transport.send_notification(method_name, params)
        expect(result).to be true
      end

      it "returns false when no sessions available" do
        expect(transport.session_manager).to receive(:active_session_ids).and_return([])

        result = transport.send_notification(method_name, params)
        expect(result).to be false
      end

      it "builds notification without params when not provided" do
        expect(transport.session_manager).to receive(:active_session_ids).and_return([session_id])
        expect(transport.stream_handler).to receive(:send_message_to_session).with(
          mock_session,
          hash_including(jsonrpc: "2.0", method: method_name)
        )

        transport.send_notification(method_name)
      end
    end

    describe "#send_notification_to_session" do
      it "sends notification to specific session" do
        expect(transport.stream_handler).to receive(:send_message_to_session).with(
          mock_session,
          hash_including(jsonrpc: "2.0", method: method_name, params: params)
        )

        result = transport.send_notification_to_session(session_id, method_name, params)
        expect(result).to be true
      end

      it "returns false for non-existent sessions" do
        allow(transport.session_manager).to receive(:get_session).with(session_id).and_return(nil)

        result = transport.send_notification_to_session(session_id, method_name, params)
        expect(result).to be false
      end

      it "builds notification without params when not provided" do
        expect(transport.stream_handler).to receive(:send_message_to_session).with(
          mock_session,
          hash_including(jsonrpc: "2.0", method: method_name)
        )

        transport.send_notification_to_session(session_id, method_name)
      end
    end

    describe "#broadcast_notification" do
      it "broadcasts notification to all sessions" do
        expect(transport.session_manager).to receive(:broadcast_message).with(
          hash_including(jsonrpc: "2.0", method: method_name, params: params)
        ).and_return(2)

        result = transport.broadcast_notification(method_name, params)
        expect(result).to eq(2)
      end
    end
  end

  describe "helper methods" do
    describe "#extract_session_id" do
      it "extracts session ID from HTTP_MCP_SESSION_ID header" do
        env = { "HTTP_MCP_SESSION_ID" => "test-session" }
        expect(transport.send(:extract_session_id, env)).to eq("test-session")
      end

      it "returns nil when header is missing" do
        env = {}
        expect(transport.send(:extract_session_id, env)).to be_nil
      end
    end

    describe "#read_request_body" do
      it "reads and rewinds request body" do
        mock_input = StringIO.new("test body")
        allow(mock_input).to receive(:rewind)
        env = { "rack.input" => mock_input }

        result = transport.send(:read_request_body, env)
        expect(result).to eq("test body")
        expect(mock_input).to have_received(:rewind)
      end
    end

    describe "#parse_json_message" do
      it "parses valid JSON" do
        json_string = '{"jsonrpc":"2.0","method":"test"}'
        result = transport.send(:parse_json_message, json_string)
        expect(result).to eq({ "jsonrpc" => "2.0", "method" => "test" })
      end

      it "raises JSON::ParserError for invalid JSON" do
        expect do
          transport.send(:parse_json_message, "invalid json")
        end.to raise_error(JSON::ParserError)
      end
    end

    describe "#build_notification" do
      it "builds notification with params" do
        result = transport.send(:build_notification, "test_method", { "key" => "value" })
        expect(result).to eq({
                               jsonrpc: "2.0",
                               method: "test_method",
                               params: { "key" => "value" }
                             })
      end

      it "builds notification without params" do
        result = transport.send(:build_notification, "test_method")
        expect(result).to eq({
                               jsonrpc: "2.0",
                               method: "test_method"
                             })
      end
    end
  end

  describe "response helpers" do
    describe "#json_response" do
      it "creates JSON response with default headers" do
        data = { "result" => "success" }
        status, headers, body = transport.send(:json_response, data)

        expect(status).to eq(200)
        expect(headers["Content-Type"]).to eq("application/json")
        expect(JSON.parse(body.first)).to eq(data)
      end

      it "merges additional headers" do
        data = { "result" => "success" }
        additional_headers = { "Custom-Header" => "value" }
        _, headers, = transport.send(:json_response, data, additional_headers)

        expect(headers["Content-Type"]).to eq("application/json")
        expect(headers["Custom-Header"]).to eq("value")
      end
    end

    describe "#json_error_response" do
      it "creates error response with data" do
        status, headers, body = transport.send(:json_error_response, 1, -32_600, "Invalid Request", { "details" => "test" })

        expect(status).to eq(400)
        expect(headers["Content-Type"]).to eq("application/json")

        response = JSON.parse(body.first)
        expect(response["jsonrpc"]).to eq("2.0")
        expect(response["id"]).to eq(1)
        expect(response["error"]["code"]).to eq(-32_600)
        expect(response["error"]["message"]).to eq("Invalid Request")
        expect(response["error"]["data"]["details"]).to eq("test")
      end

      it "creates error response without data" do
        _, _, body = transport.send(:json_error_response, nil, -32_700, "Parse error")

        response = JSON.parse(body.first)
        expect(response["error"]).not_to have_key("data")
      end
    end
  end

  describe "#stop" do
    let(:mock_puma_server) { instance_double("Puma::Server", stop: nil) }

    before do
      transport.instance_variable_set(:@puma_server, mock_puma_server)
      allow(transport.session_manager).to receive(:cleanup_all_sessions)
    end

    it "stops the server and cleans up resources" do
      expect(mock_logger).to receive(:info) { |&block| expect(block.call).to include("Stopping HttpStream transport") }
      expect(mock_logger).to receive(:info) { |&block| expect(block.call).to include("HttpStream transport stopped") }
      expect(transport.session_manager).to receive(:cleanup_all_sessions)
      expect(mock_puma_server).to receive(:stop)

      transport.stop
    end

    it "handles missing puma server gracefully" do
      transport.instance_variable_set(:@puma_server, nil)

      expect { transport.stop }.not_to raise_error
    end
  end

  describe "error handling scenarios" do
    describe "request processing errors" do
      it "handles StandardError during request processing" do
        allow(transport).to receive(:route_request).and_raise(StandardError.new("Test error"))

        get "/mcp"

        expect(last_response.status).to eq(500)
        expect(last_response.body).to eq("Internal Server Error")
      end
    end

    describe "message handling errors" do
      let(:session_id) { "test-session" }
      let(:json_request) { { "jsonrpc" => "2.0", "id" => 1, "method" => "test" }.to_json }

      before do
        allow(transport.session_manager).to receive(:get_or_create_session).and_return(mock_session)
      end

      it "handles VectorMCP::ProtocolError" do
        error = VectorMCP::InvalidParamsError.new("Invalid parameters", request_id: 1)
        allow(mock_mcp_server).to receive(:handle_message).and_raise(error)

        post "/mcp", json_request, "HTTP_MCP_SESSION_ID" => session_id, "CONTENT_TYPE" => "application/json"

        expect(last_response.status).to eq(400)
        response = JSON.parse(last_response.body)
        expect(response["error"]["code"]).to eq(-32_602)
        expect(response["error"]["message"]).to eq("Invalid parameters")
      end
    end
  end

  describe "lifecycle methods" do
    describe "private helper methods" do
      describe "#normalize_path_prefix" do
        [
          [nil, "/"],
          ["", "/"],
          ["custom", "/custom"],
          ["/custom", "/custom"],
          ["custom/", "/custom"],
          ["/custom/", "/custom"],
          ["api/v1", "/api/v1"],
          ["/api/v1/", "/api/v1"]
        ].each do |input, expected|
          it "normalizes #{input.inspect} to '#{expected}'" do
            result = transport.send(:normalize_path_prefix, input)
            expect(result).to eq(expected)
          end
        end
      end
    end
  end
end
