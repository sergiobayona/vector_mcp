# frozen_string_literal: true

require "spec_helper"
require "vector_mcp/transport/http_stream"

RSpec.describe VectorMCP::Transport::HttpStream::SessionManager, "context integration" do
  let(:server) { instance_double(VectorMCP::Server, logger: logger) }
  let(:logger) { instance_double(Logger, info: nil, debug: nil, error: nil) }
  let(:transport) { instance_double(VectorMCP::Transport::HttpStream, server: server, logger: logger) }
  let(:session_manager) { described_class.new(transport, 3600) }

  describe "session creation with request context" do
    let(:rack_env) do
      {
        "REQUEST_METHOD" => "POST",
        "PATH_INFO" => "/mcp",
        "QUERY_STRING" => "api_key=test123&format=json",
        "HTTP_AUTHORIZATION" => "Bearer token123",
        "HTTP_X_API_KEY" => "secret456",
        "HTTP_USER_AGENT" => "TestClient/1.0",
        "CONTENT_TYPE" => "application/json",
        "REMOTE_ADDR" => "127.0.0.1",
        "HTTP_MCP_SESSION_ID" => "test-session-123"
      }
    end

    describe "session_manager.create_session" do
      it "creates session with context from rack_env" do
        session = session_manager.create_session("test-session", rack_env)

        expect(session.id).to eq("test-session")
        expect(session.context).to be_a(VectorMCP::Session)

        # Verify request context is populated
        request_context = session.context.request_context
        expect(request_context).to be_a(VectorMCP::RequestContext)
        expect(request_context.method).to eq("POST")
        expect(request_context.path).to eq("/mcp")
        expect(request_context.header("Authorization")).to eq("Bearer token123")
        expect(request_context.header("X-API-Key")).to eq("secret456")
        expect(request_context.param("api_key")).to eq("test123")
        expect(request_context.param("format")).to eq("json")
        expect(request_context.metadata("transport_type")).to eq("http_stream")
        expect(request_context.metadata("remote_addr")).to eq("127.0.0.1")
        expect(request_context.metadata("user_agent")).to eq("TestClient/1.0")
      end

      it "creates session with minimal context when rack_env is nil" do
        session = session_manager.create_session("test-session", nil)

        expect(session.id).to eq("test-session")
        expect(session.context).to be_a(VectorMCP::Session)

        # Verify minimal context is populated
        request_context = session.context.request_context
        expect(request_context).to be_a(VectorMCP::RequestContext)
        expect(request_context.method).to eq("HTTP_STREAM")
        expect(request_context.path).to eq("/")
        expect(request_context.headers).to eq({})
        expect(request_context.params).to eq({})
        expect(request_context.metadata("transport_type")).to eq("http_stream")
      end
    end

    describe "session_manager.get_or_create_session" do
      it "creates new session with context" do
        session = session_manager.get_or_create_session("new-session", rack_env)

        expect(session.id).to eq("new-session")
        request_context = session.context.request_context
        expect(request_context.header("Authorization")).to eq("Bearer token123")
        expect(request_context.param("api_key")).to eq("test123")
      end

      it "updates existing session context" do
        # Create initial session
        session_manager.create_session("existing-session", {
                                         "REQUEST_METHOD" => "GET",
                                         "PATH_INFO" => "/test",
                                         "HTTP_X_OLD_HEADER" => "old-value"
                                       })

        # Get session again with new rack_env
        updated_session = session_manager.get_or_create_session("existing-session", rack_env)

        expect(updated_session.id).to eq("existing-session")
        request_context = updated_session.context.request_context
        expect(request_context.method).to eq("POST") # Updated
        expect(request_context.path).to eq("/mcp") # Updated
        expect(request_context.header("Authorization")).to eq("Bearer token123") # New
        expect(request_context.header("X-Old-Header")).to be_nil # Old headers not preserved
      end

      it "returns existing session without updating context when rack_env is nil" do
        # Create initial session with context
        initial_session = session_manager.create_session("existing-session", rack_env)
        initial_context = initial_session.context.request_context

        # Get session again without rack_env
        same_session = session_manager.get_or_create_session("existing-session", nil)

        expect(same_session.id).to eq("existing-session")
        expect(same_session.context.request_context).to eq(initial_context)
      end
    end

    describe "create_session_with_context" do
      it "creates VectorMCP::Session with rack_env context" do
        session = session_manager.send(:create_session_with_context, "test-session", rack_env)

        expect(session).to be_a(VectorMCP::Session)
        expect(session.id).to eq("test-session")
        expect(session.server).to eq(server)
        expect(session.transport).to eq(transport)

        request_context = session.request_context
        expect(request_context.method).to eq("POST")
        expect(request_context.path).to eq("/mcp")
        expect(request_context.header("Authorization")).to eq("Bearer token123")
        expect(request_context.param("api_key")).to eq("test123")
        expect(request_context.metadata("transport_type")).to eq("http_stream")
      end

      it "creates VectorMCP::Session with minimal context when rack_env is nil" do
        session = session_manager.send(:create_session_with_context, "test-session", nil)

        expect(session).to be_a(VectorMCP::Session)
        expect(session.id).to eq("test-session")

        request_context = session.request_context
        expect(request_context.method).to eq("HTTP_STREAM")
        expect(request_context.path).to eq("/")
        expect(request_context.headers).to eq({})
        expect(request_context.params).to eq({})
        expect(request_context.metadata("transport_type")).to eq("http_stream")
      end
    end
  end

  describe "transport integration" do
    let(:real_transport) { VectorMCP::Transport::HttpStream.new(server, port: 0) }
    let(:mock_session) { instance_double(VectorMCP::Transport::HttpStream::SessionManager::Session) }
    let(:mock_vector_session) { instance_double(VectorMCP::Session) }
    let(:mock_request_context) { instance_double(VectorMCP::RequestContext) }

    before do
      allow(mock_session).to receive(:context).and_return(mock_vector_session)
      allow(mock_session).to receive(:id).and_return("test-session")
      allow(mock_vector_session).to receive(:request_context).and_return(mock_request_context)
      allow(mock_vector_session).to receive(:id).and_return("test-session")
      allow(mock_request_context).to receive(:headers).and_return({})
      allow(mock_request_context).to receive(:params).and_return({})
    end

    describe "handle_post_request" do
      it "passes rack_env to session creation" do
        # Use real transport but mock its session manager
        real_session_manager = real_transport.instance_variable_get(:@session_manager)
        allow(real_session_manager).to receive(:get_or_create_session).with("test-session", anything).and_return(mock_session)
        allow(server).to receive(:handle_message).and_return({ jsonrpc: "2.0", id: 1, result: "ok" })
        
        rack_env = {
          "REQUEST_METHOD" => "POST",
          "HTTP_MCP_SESSION_ID" => "test-session",
          "rack.input" => StringIO.new('{"jsonrpc":"2.0","method":"test","id":1}')
        }

        result = real_transport.send(:handle_post_request, rack_env)

        expect(real_session_manager).to have_received(:get_or_create_session).with("test-session", anything)
        expect(result).to be_an(Array) # Rack response
      end
    end

    describe "handle_get_request" do
      it "passes rack_env to session creation for streaming" do
        # Use real transport but mock its session manager and stream handler
        real_session_manager = real_transport.instance_variable_get(:@session_manager)
        real_stream_handler = real_transport.instance_variable_get(:@stream_handler)
        
        allow(real_session_manager).to receive(:get_or_create_session).with("test-session", anything).and_return(mock_session)
        allow(real_stream_handler).to receive(:handle_streaming_request).and_return([200, {}, []])
        
        rack_env = {
          "REQUEST_METHOD" => "GET",
          "HTTP_MCP_SESSION_ID" => "test-session",
          "HTTP_ACCEPT" => "text/event-stream"
        }

        result = real_transport.send(:handle_get_request, rack_env)

        expect(real_session_manager).to have_received(:get_or_create_session).with("test-session", anything)
        expect(result).to be_an(Array) # Rack response
      end
    end
  end

  describe "edge cases" do
    it "handles malformed rack_env gracefully" do
      malformed_env = {
        "REQUEST_METHOD" => "POST",
        "PATH_INFO" => "/mcp",
        "QUERY_STRING" => "invalid=query&string&format", # Malformed query
        "HTTP_AUTHORIZATION" => nil # Nil header
      }

      session = session_manager.create_session("test-session", malformed_env)

      expect(session.id).to eq("test-session")
      request_context = session.context.request_context
      expect(request_context.method).to eq("POST")
      expect(request_context.path).to eq("/mcp")
      expect(request_context.header("Authorization")).to eq("") # Normalized nil to empty string
      expect(request_context.params).to include("invalid" => "query") # Parsed what it could
    end

    it "handles empty rack_env" do
      empty_env = {}

      session = session_manager.create_session("test-session", empty_env)

      expect(session.id).to eq("test-session")
      request_context = session.context.request_context
      expect(request_context.method).to be_nil
      expect(request_context.path).to be_nil
      expect(request_context.headers).to eq({})
      expect(request_context.params).to eq({})
      expect(request_context.metadata("transport_type")).to eq("http_stream")
    end
  end
end
