# frozen_string_literal: true

require "spec_helper"
require "vector_mcp/transport/http_stream"

RSpec.describe VectorMCP::Transport::HttpStream::SessionManager do
  let(:server) { instance_double(VectorMCP::Server, logger: logger) }
  let(:logger) { instance_double(Logger, info: nil, debug: nil, error: nil, warn: nil) }
  let(:transport) { instance_double(VectorMCP::Transport::HttpStream, server: server, logger: logger) }
  let(:session_manager) { described_class.new(transport, session_timeout) }
  let(:session_timeout) { 300 }

  describe "#initialize" do
    it "initializes with transport and session timeout" do
      expect(session_manager.instance_variable_get(:@transport)).to eq(transport)
      expect(session_manager.instance_variable_get(:@session_timeout)).to eq(session_timeout)
    end

    it "initializes with empty sessions hash" do
      sessions = session_manager.instance_variable_get(:@sessions)
      expect(sessions).to be_a(Concurrent::Hash)
      expect(sessions).to be_empty
    end

    it "starts cleanup timer" do
      cleanup_timer = session_manager.instance_variable_get(:@cleanup_timer)
      expect(cleanup_timer).to be_a(Concurrent::TimerTask)
    end
  end

  describe "#create_session" do
    let(:rack_env) do
      {
        "REQUEST_METHOD" => "POST",
        "PATH_INFO" => "/mcp",
        "HTTP_AUTHORIZATION" => "Bearer token123",
        "HTTP_X_API_KEY" => "secret456",
        "REMOTE_ADDR" => "127.0.0.1"
      }
    end

    context "with specific session ID" do
      let(:session_id) { "custom-session-123" }

      it "creates session with specified ID" do
        session = session_manager.create_session(session_id, rack_env)

        expect(session.id).to eq(session_id)
        expect(session.context).to be_a(VectorMCP::Session)
        expect(session.context.server).to eq(server)
        expect(session.context.transport).to eq(transport)
      end

      it "creates session with request context from rack_env" do
        session = session_manager.create_session(session_id, rack_env)

        request_context = session.context.request_context
        expect(request_context).to be_a(VectorMCP::RequestContext)
        expect(request_context.method).to eq("POST")
        expect(request_context.path).to eq("/mcp")
        expect(request_context.header("Authorization")).to eq("Bearer token123")
        expect(request_context.header("X-API-Key")).to eq("secret456")
        expect(request_context.metadata("transport_type")).to eq("http_stream")
        expect(request_context.metadata("remote_addr")).to eq("127.0.0.1")
      end

      it "creates session with minimal context when rack_env is nil" do
        session = session_manager.create_session(session_id, nil)

        request_context = session.context.request_context
        expect(request_context).to be_a(VectorMCP::RequestContext)
        expect(request_context.method).to eq("HTTP_STREAM")
        expect(request_context.path).to eq("/")
        expect(request_context.headers).to eq({})
        expect(request_context.params).to eq({})
        expect(request_context.metadata("transport_type")).to eq("http_stream")
      end

      it "stores session in sessions hash" do
        session = session_manager.create_session(session_id, rack_env)

        sessions = session_manager.instance_variable_get(:@sessions)
        expect(sessions[session_id]).to eq(session)
      end
    end

    context "with auto-generated session ID" do
      it "creates session with random ID" do
        session = session_manager.create_session(nil, rack_env)

        expect(session.id).to be_a(String)
        expect(session.id).not_to be_empty
        expect(session.id).to match(/^[a-f0-9\-]+$/) # UUID-like format
      end

      it "creates unique session IDs" do
        session1 = session_manager.create_session(nil, rack_env)
        session2 = session_manager.create_session(nil, rack_env)

        expect(session1.id).not_to eq(session2.id)
      end
    end

    it "logs session creation" do
      expect(logger).to receive(:info)

      session_manager.create_session("test-session", rack_env)
    end
  end

  describe "#get_or_create_session" do
    let(:session_id) { "existing-session" }
    let(:rack_env) do
      {
        "REQUEST_METHOD" => "GET",
        "PATH_INFO" => "/mcp",
        "HTTP_AUTHORIZATION" => "Bearer new-token"
      }
    end

    context "when session exists" do
      let(:existing_session) { session_manager.create_session(session_id) }

      before do
        existing_session # Create the session
      end

      it "returns existing session" do
        result = session_manager.get_or_create_session(session_id, rack_env)

        expect(result).to eq(existing_session)
      end

      it "updates existing session context when rack_env provided" do
        original_context = existing_session.context.request_context
        expect(original_context.method).to eq("HTTP_STREAM")

        result = session_manager.get_or_create_session(session_id, rack_env)

        updated_context = result.context.request_context
        expect(updated_context.method).to eq("GET")
        expect(updated_context.path).to eq("/mcp")
        expect(updated_context.header("Authorization")).to eq("Bearer new-token")
      end

      it "does not update context when rack_env is nil" do
        original_context = existing_session.context.request_context
        original_method = original_context.method

        result = session_manager.get_or_create_session(session_id, nil)

        expect(result.context.request_context.method).to eq(original_method)
      end

      it "touches session to update last_accessed" do
        expect(existing_session).to receive(:touch!)

        session_manager.get_or_create_session(session_id, rack_env)
      end
    end

    context "when session does not exist" do
      it "creates new session with provided ID" do
        result = session_manager.get_or_create_session(session_id, rack_env)

        expect(result.id).to eq(session_id)
        expect(result.context).to be_a(VectorMCP::Session)
      end

      it "creates new session with auto-generated ID when nil provided" do
        result = session_manager.get_or_create_session(nil, rack_env)

        expect(result.id).to be_a(String)
        expect(result.id).not_to be_empty
      end
    end
  end

  describe "#get_session" do
    let(:session_id) { "test-session" }

    context "when session exists" do
      let(:existing_session) { session_manager.create_session(session_id) }

      before do
        existing_session # Create the session
      end

      it "returns the session" do
        result = session_manager.get_session(session_id)

        expect(result).to eq(existing_session)
      end

      it "touches session to update last_accessed" do
        expect(existing_session).to receive(:touch!)

        session_manager.get_session(session_id)
      end
    end

    context "when session does not exist" do
      it "returns nil" do
        result = session_manager.get_session("non-existent")

        expect(result).to be_nil
      end
    end
  end

  describe "#terminate_session" do
    let(:session_id) { "test-session" }

    context "when session exists" do
      let(:existing_session) { session_manager.create_session(session_id) }

      before do
        existing_session # Create the session
      end

      it "removes session from sessions hash" do
        result = session_manager.terminate_session(session_id)

        expect(result).to be true
        sessions = session_manager.instance_variable_get(:@sessions)
        expect(sessions[session_id]).to be_nil
      end

      it "cleans up streaming connection if present" do
        # Set up a mock streaming connection
        connection = instance_double(VectorMCP::Transport::HttpStream::StreamHandler::StreamingConnection)
        existing_session.streaming_connection = connection

        expect(connection).to receive(:close)

        session_manager.terminate_session(session_id)
      end

      it "logs session termination" do
        expect(logger).to receive(:info)

        session_manager.terminate_session(session_id)
      end
    end

    context "when session does not exist" do
      it "returns false" do
        result = session_manager.terminate_session("non-existent")

        expect(result).to be false
      end
    end
  end

  describe "#active_session_ids" do
    it "returns empty array when no sessions exist" do
      result = session_manager.active_session_ids

      expect(result).to eq([])
    end

    it "returns array of session IDs" do
      session1 = session_manager.create_session("session-1")
      session2 = session_manager.create_session("session-2")

      result = session_manager.active_session_ids

      expect(result).to contain_exactly("session-1", "session-2")
    end
  end

  describe "#session_count" do
    it "returns 0 when no sessions exist" do
      result = session_manager.session_count

      expect(result).to eq(0)
    end

    it "returns count of all sessions" do
      session_manager.create_session("session-1")
      session_manager.create_session("session-2")

      result = session_manager.session_count

      expect(result).to eq(2)
    end
  end

  describe "#broadcast_message" do
    let(:message) { { jsonrpc: "2.0", method: "notification", params: { data: "test" } } }
    let(:stream_handler) { instance_double(VectorMCP::Transport::HttpStream::StreamHandler) }

    before do
      allow(transport).to receive(:stream_handler).and_return(stream_handler)
    end

    it "returns 0 when no sessions exist" do
      result = session_manager.broadcast_message(message)

      expect(result).to eq(0)
    end

    it "sends message to all streaming sessions" do
      session1 = session_manager.create_session("session-1")
      session2 = session_manager.create_session("session-2")
      session3 = session_manager.create_session("session-3")

      # Mock streaming status
      allow(session1).to receive(:streaming?).and_return(true)
      allow(session2).to receive(:streaming?).and_return(false)
      allow(session3).to receive(:streaming?).and_return(true)

      expect(stream_handler).to receive(:send_message_to_session).with(session1, message).and_return(true)
      expect(stream_handler).to receive(:send_message_to_session).with(session3, message).and_return(true)

      result = session_manager.broadcast_message(message)

      expect(result).to eq(2)
    end

    it "handles message sending failures gracefully" do
      session1 = session_manager.create_session("session-1")
      allow(session1).to receive(:streaming?).and_return(true)

      expect(stream_handler).to receive(:send_message_to_session).with(session1, message).and_return(false)

      result = session_manager.broadcast_message(message)

      expect(result).to eq(0)
    end
  end

  describe "#cleanup_expired_sessions" do
    let(:session_timeout) { 1 } # 1 second timeout for testing

    it "removes expired sessions" do
      session1 = session_manager.create_session("session-1")
      session2 = session_manager.create_session("session-2")

      # Mock expiration
      allow(session1).to receive(:expired?).and_return(true)
      allow(session2).to receive(:expired?).and_return(false)

      session_manager.send(:cleanup_expired_sessions)

      sessions = session_manager.instance_variable_get(:@sessions)
      expect(sessions["session-1"]).to be_nil
      expect(sessions["session-2"]).to eq(session2)
    end

    it "cleans up streaming connections for expired sessions" do
      session = session_manager.create_session("session-1")
      connection = instance_double(VectorMCP::Transport::HttpStream::StreamHandler::StreamingConnection)
      session.streaming_connection = connection

      allow(session).to receive(:expired?).and_return(true)
      expect(connection).to receive(:close)

      session_manager.send(:cleanup_expired_sessions)
    end

    it "logs cleanup activity when sessions are expired" do
      session = session_manager.create_session("session-1")
      allow(session).to receive(:expired?).and_return(true)

      expect(logger).to receive(:info)

      session_manager.send(:cleanup_expired_sessions)
    end
  end

  describe "#cleanup_all_sessions" do
    it "terminates all sessions" do
      session1 = session_manager.create_session("session-1")
      session2 = session_manager.create_session("session-2")

      session_manager.cleanup_all_sessions

      sessions = session_manager.instance_variable_get(:@sessions)
      expect(sessions).to be_empty
    end

    it "stops cleanup timer" do
      cleanup_timer = session_manager.instance_variable_get(:@cleanup_timer)
      expect(cleanup_timer).to receive(:shutdown)

      session_manager.cleanup_all_sessions
    end

    it "logs cleanup activity" do
      session_manager.create_session("session-1")
      expect(logger).to receive(:info)

      session_manager.cleanup_all_sessions
    end
  end

  describe "session expiration" do
    it "creates Session objects with proper expiration handling" do
      session = session_manager.create_session("test-session")

      expect(session).to respond_to(:expired?)
      expect(session).to respond_to(:touch!)
      expect(session).to respond_to(:age)
    end
  end

  describe "thread safety" do
    it "handles concurrent session creation" do
      sessions = []
      threads = []

      10.times do |i|
        threads << Thread.new do
          session = session_manager.create_session("session-#{i}")
          sessions << session
        end
      end

      threads.each(&:join)

      expect(sessions.length).to eq(10)
      expect(sessions.map(&:id).uniq.length).to eq(10)
    end

    it "handles concurrent session access" do
      session = session_manager.create_session("test-session")
      results = []
      threads = []

      10.times do
        threads << Thread.new do
          result = session_manager.get_session("test-session")
          results << result
        end
      end

      threads.each(&:join)

      expect(results.length).to eq(10)
      expect(results.uniq.length).to eq(1)
      expect(results.first).to eq(session)
    end
  end
end