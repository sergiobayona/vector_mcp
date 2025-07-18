# frozen_string_literal: true

require "spec_helper"
require "vector_mcp/transport/sse"

RSpec.describe VectorMCP::Transport::SseSessionManager, "context integration" do
  let(:server) { instance_double(VectorMCP::Server, logger: logger) }
  let(:logger) { instance_double(Logger, info: nil, debug: nil, error: nil) }
  let(:transport) { instance_double(VectorMCP::Transport::SSE, server: server, logger: logger) }
  let(:session_manager) { described_class.new(transport, 3600) }

  describe "session creation with request context" do
    let(:rack_env) do
      {
        "REQUEST_METHOD" => "POST",
        "PATH_INFO" => "/sse",
        "QUERY_STRING" => "session_id=sse-session&mode=stream",
        "HTTP_AUTHORIZATION" => "Bearer sse-token",
        "HTTP_X_API_KEY" => "sse-secret",
        "HTTP_USER_AGENT" => "SSEClient/1.0",
        "CONTENT_TYPE" => "text/event-stream",
        "REMOTE_ADDR" => "192.168.1.1",
        "HTTP_ACCEPT" => "text/event-stream"
      }
    end

    describe "create_shared_session" do
      it "creates session with context from rack_env" do
        session = session_manager.send(:create_shared_session, rack_env)

        expect(session.id).to start_with("sse_shared_session_")
        expect(session.context).to be_a(VectorMCP::Session)

        # Verify request context is populated
        request_context = session.context.request_context
        expect(request_context).to be_a(VectorMCP::RequestContext)
        expect(request_context.method).to eq("POST")
        expect(request_context.path).to eq("/sse")
        expect(request_context.header("Authorization")).to eq("Bearer sse-token")
        expect(request_context.header("X-API-Key")).to eq("sse-secret")
        expect(request_context.header("Accept")).to eq("text/event-stream")
        expect(request_context.param("session_id")).to eq("sse-session")
        expect(request_context.param("mode")).to eq("stream")
        expect(request_context.metadata("transport_type")).to eq("sse")
        expect(request_context.metadata("remote_addr")).to eq("192.168.1.1")
        expect(request_context.metadata("user_agent")).to eq("SSEClient/1.0")
      end

      it "creates session with minimal context when rack_env is nil" do
        session = session_manager.send(:create_shared_session, nil)

        expect(session.id).to start_with("sse_shared_session_")
        expect(session.context).to be_a(VectorMCP::Session)

        # Verify minimal context is populated
        request_context = session.context.request_context
        expect(request_context).to be_a(VectorMCP::RequestContext)
        expect(request_context.method).to eq("SSE")
        expect(request_context.path).to eq("/")
        expect(request_context.headers).to eq({})
        expect(request_context.params).to eq({})
        expect(request_context.metadata("transport_type")).to eq("sse")
      end

      it "creates session with minimal context when rack_env is empty" do
        session = session_manager.send(:create_shared_session, {})

        expect(session.id).to start_with("sse_shared_session_")

        request_context = session.context.request_context
        expect(request_context.method).to be_nil
        expect(request_context.path).to be_nil
        expect(request_context.headers).to eq({})
        expect(request_context.params).to eq({})
        expect(request_context.metadata("transport_type")).to eq("sse")
      end
    end

    describe "create_session_with_context" do
      it "creates VectorMCP::Session with rack_env context" do
        session = session_manager.send(:create_session_with_context, "sse-test-session", rack_env)

        expect(session).to be_a(VectorMCP::Session)
        expect(session.id).to eq("sse-test-session")
        expect(session.server).to eq(server)
        expect(session.transport).to eq(transport)

        request_context = session.request_context
        expect(request_context.method).to eq("POST")
        expect(request_context.path).to eq("/sse")
        expect(request_context.header("Authorization")).to eq("Bearer sse-token")
        expect(request_context.param("session_id")).to eq("sse-session")
        expect(request_context.metadata("transport_type")).to eq("sse")
        expect(request_context.metadata("content_type")).to eq("text/event-stream")
      end

      it "creates VectorMCP::Session with minimal context when rack_env is nil" do
        session = session_manager.send(:create_session_with_context, "sse-test-session", nil)

        expect(session).to be_a(VectorMCP::Session)
        expect(session.id).to eq("sse-test-session")

        request_context = session.request_context
        expect(request_context.method).to eq("SSE")
        expect(request_context.path).to eq("/")
        expect(request_context.headers).to eq({})
        expect(request_context.params).to eq({})
        expect(request_context.metadata("transport_type")).to eq("sse")
      end
    end
  end

  describe "session lifecycle with context" do
    let(:simple_rack_env) do
      {
        "REQUEST_METHOD" => "GET",
        "PATH_INFO" => "/events",
        "HTTP_X_SESSION_ID" => "persistent-session"
      }
    end

    it "maintains context across session lifecycle" do
      # Create session
      session = session_manager.send(:create_shared_session, simple_rack_env)
      session_id = session.id

      # Verify session is stored and context is maintained
      retrieved_session = session_manager.get_session(session_id)
      expect(retrieved_session).to eq(session)

      request_context = retrieved_session.context.request_context
      expect(request_context.method).to eq("GET")
      expect(request_context.path).to eq("/events")
      expect(request_context.header("X-Session-Id")).to eq("persistent-session")
    end

    it "preserves context when session is touched" do
      session = session_manager.send(:create_shared_session, simple_rack_env)
      original_context = session.context.request_context

      # Touch session (simulate activity)
      session.touch!

      # Verify context is preserved
      expect(session.context.request_context).to eq(original_context)
      expect(session.context.request_context.method).to eq("GET")
      expect(session.context.request_context.path).to eq("/events")
    end
  end

  describe "SSE-specific context features" do
    let(:streaming_rack_env) do
      {
        "REQUEST_METHOD" => "GET",
        "PATH_INFO" => "/stream",
        "HTTP_ACCEPT" => "text/event-stream",
        "HTTP_CACHE_CONTROL" => "no-cache",
        "HTTP_CONNECTION" => "keep-alive",
        "QUERY_STRING" => "last_event_id=event-123&timeout=30"
      }
    end

    it "captures SSE-specific headers and parameters" do
      session = session_manager.send(:create_shared_session, streaming_rack_env)

      request_context = session.context.request_context
      expect(request_context.header("Accept")).to eq("text/event-stream")
      expect(request_context.header("Cache-Control")).to eq("no-cache")
      expect(request_context.header("Connection")).to eq("keep-alive")
      expect(request_context.param("last_event_id")).to eq("event-123")
      expect(request_context.param("timeout")).to eq("30")
    end

    it "handles SSE reconnection scenarios" do
      # Initial connection
      initial_session = session_manager.send(:create_shared_session, streaming_rack_env)
      initial_session.context.request_context

      # Reconnection with Last-Event-ID
      reconnect_env = streaming_rack_env.merge({
                                                 "HTTP_LAST_EVENT_ID" => "event-456",
                                                 "QUERY_STRING" => "reconnect=true"
                                               })

      reconnect_session = session_manager.send(:create_shared_session, reconnect_env)
      reconnect_context = reconnect_session.context.request_context

      expect(reconnect_context.header("Last-Event-Id")).to eq("event-456")
      expect(reconnect_context.param("reconnect")).to eq("true")
      expect(reconnect_context.metadata("transport_type")).to eq("sse")
    end
  end

  describe "edge cases and error handling" do
    it "handles malformed SSE request gracefully" do
      malformed_env = {
        "REQUEST_METHOD" => "POST", # Unusual for SSE
        "PATH_INFO" => "/sse",
        "QUERY_STRING" => "malformed&query&string=",
        "HTTP_AUTHORIZATION" => "", # Empty auth header
        "HTTP_ACCEPT" => "application/json" # Not typical for SSE
      }

      session = session_manager.send(:create_shared_session, malformed_env)

      expect(session.id).to start_with("sse_shared_session_")
      request_context = session.context.request_context
      expect(request_context.method).to eq("POST")
      expect(request_context.path).to eq("/sse")
      expect(request_context.header("Authorization")).to eq("")
      expect(request_context.header("Accept")).to eq("application/json")
      expect(request_context.params).to include("malformed" => "")
    end

    it "handles session creation with concurrent access" do
      # Simulate concurrent session creation
      sessions = []
      threads = []

      5.times do |i|
        threads << Thread.new do
          env = {
            "REQUEST_METHOD" => "GET",
            "PATH_INFO" => "/concurrent",
            "HTTP_X_THREAD_ID" => "thread-#{i}"
          }
          sessions << session_manager.send(:create_shared_session, env)
        end
      end

      threads.each(&:join)

      # Verify all sessions were created with unique IDs
      session_ids = sessions.map { |s| s.id }
      expect(session_ids.uniq.length).to eq(5)

      # Verify each session has correct context
      sessions.each_with_index do |session, i|
        context = session.context.request_context
        expect(context.method).to eq("GET")
        expect(context.path).to eq("/concurrent")
        expect(context.header("X-Thread-Id")).to eq("thread-#{i}")
      end
    end
  end
end
