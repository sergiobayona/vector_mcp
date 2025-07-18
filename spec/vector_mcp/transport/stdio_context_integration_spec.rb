# frozen_string_literal: true

require "spec_helper"
require "vector_mcp/transport/stdio"

RSpec.describe VectorMCP::Transport::StdioSessionManager, "context integration" do
  let(:server) { instance_double(VectorMCP::Server, logger: logger) }
  let(:logger) { instance_double(Logger, info: nil, debug: nil, error: nil) }
  let(:transport) { instance_double(VectorMCP::Transport::Stdio, server: server, logger: logger) }
  let(:session_manager) { described_class.new(transport, 3600) }

  describe "session creation with request context" do
    describe "create_global_session" do
      it "creates session with minimal context for stdio transport" do
        session = session_manager.get_global_session

        expect(session.id).to eq(VectorMCP::Transport::StdioSessionManager::GLOBAL_SESSION_ID)
        expect(session.context).to be_a(VectorMCP::Session)

        # Verify minimal context is populated
        request_context = session.context.request_context
        expect(request_context).to be_a(VectorMCP::RequestContext)
        expect(request_context.method).to eq("STDIO")
        expect(request_context.path).to eq("/")
        expect(request_context.headers).to eq({})
        expect(request_context.params).to eq({})
        expect(request_context.metadata("transport_type")).to eq("stdio")
      end

      it "creates session with proper server and transport references" do
        session = session_manager.get_global_session

        vector_session = session.context
        expect(vector_session.id).to eq(VectorMCP::Transport::StdioSessionManager::GLOBAL_SESSION_ID)
        expect(vector_session.server).to eq(server)
        expect(vector_session.transport).to eq(transport)
      end

      it "creates session with immutable context" do
        session = session_manager.get_global_session

        request_context = session.context.request_context
        expect(request_context.headers).to be_frozen
        expect(request_context.params).to be_frozen
        expect(request_context.transport_metadata).to be_frozen
      end
    end

    describe "get_or_create_global_session" do
      it "creates global session on first call" do
        session = session_manager.get_or_create_global_session

        expect(session.id).to eq(VectorMCP::Transport::StdioSessionManager::GLOBAL_SESSION_ID)
        expect(session.context).to be_a(VectorMCP::Session)

        request_context = session.context.request_context
        expect(request_context.method).to eq("STDIO")
        expect(request_context.metadata("transport_type")).to eq("stdio")
      end

      it "returns same session on subsequent calls" do
        first_session = session_manager.get_or_create_global_session
        second_session = session_manager.get_or_create_global_session

        expect(first_session).to eq(second_session)
        expect(first_session.id).to eq(second_session.id)
        expect(first_session.context.request_context).to eq(second_session.context.request_context)
      end

      it "maintains context across multiple calls" do
        session1 = session_manager.get_or_create_global_session
        session2 = session_manager.get_or_create_global_session

        context1 = session1.context.request_context
        context2 = session2.context.request_context

        expect(context1.method).to eq("STDIO")
        expect(context2.method).to eq("STDIO")
        expect(context1.metadata("transport_type")).to eq("stdio")
        expect(context2.metadata("transport_type")).to eq("stdio")
      end
    end

    describe "session lifecycle" do
      it "maintains context through session operations" do
        session = session_manager.get_global_session
        original_context = session.context.request_context

        # Touch session (simulate activity)
        session.touch!

        # Verify context is preserved
        expect(session.context.request_context).to eq(original_context)
        expect(session.context.request_context.method).to eq("STDIO")
        expect(session.context.request_context.path).to eq("/")
      end

      it "allows session data modification without affecting context" do
        session = session_manager.get_global_session
        original_context = session.context.request_context

        # Modify session data
        session.context.data[:custom_key] = "custom_value"

        # Verify context is unchanged
        expect(session.context.request_context).to eq(original_context)
        expect(session.context.request_context.metadata("transport_type")).to eq("stdio")
        expect(session.context.data[:custom_key]).to eq("custom_value")
      end
    end
  end

  describe "stdio-specific context features" do
    it "provides context suitable for command-line usage" do
      session = session_manager.get_global_session

      request_context = session.context.request_context
      expect(request_context.http_transport?).to be false
      expect(request_context.has_headers?).to be false
      expect(request_context.has_params?).to be false
      expect(request_context.metadata("transport_type")).to eq("stdio")
    end

    it "supports context updates for stdio-specific operations" do
      session = session_manager.get_global_session

      # Update context with stdio-specific metadata
      session.context.update_request_context(
        transport_metadata: {
          "transport_type" => "stdio",
          "stdin_available" => true,
          "stdout_available" => true,
          "command_line_args" => ["--verbose", "--port", "8080"]
        }
      )

      request_context = session.context.request_context
      expect(request_context.metadata("transport_type")).to eq("stdio")
      expect(request_context.metadata("stdin_available")).to eq(true)
      expect(request_context.metadata("stdout_available")).to eq(true)
      expect(request_context.metadata("command_line_args")).to eq(["--verbose", "--port", "8080"])
    end

    it "maintains consistent session ID across operations" do
      session1 = session_manager.get_global_session
      session2 = session_manager.get_or_create_global_session

      expect(session1.id).to eq(VectorMCP::Transport::StdioSessionManager::GLOBAL_SESSION_ID)
      expect(session2.id).to eq(VectorMCP::Transport::StdioSessionManager::GLOBAL_SESSION_ID)
      expect(session1.id).to eq(session2.id)
    end
  end

  describe "context consistency and validation" do
    it "creates context with proper VectorMCP::RequestContext structure" do
      session = session_manager.get_global_session

      request_context = session.context.request_context
      expect(request_context).to respond_to(:headers)
      expect(request_context).to respond_to(:params)
      expect(request_context).to respond_to(:method)
      expect(request_context).to respond_to(:path)
      expect(request_context).to respond_to(:transport_metadata)
      expect(request_context).to respond_to(:header)
      expect(request_context).to respond_to(:param)
      expect(request_context).to respond_to(:metadata)
      expect(request_context).to respond_to(:to_h)
    end

    it "provides consistent context hash representation" do
      session = session_manager.get_global_session

      context_hash = session.context.request_context.to_h
      expected_hash = {
        headers: {},
        params: {},
        method: "STDIO",
        path: "/",
        transport_metadata: { "transport_type" => "stdio" }
      }

      expect(context_hash).to eq(expected_hash)
    end

    it "supports context serialization and debugging" do
      session = session_manager.get_global_session

      request_context = session.context.request_context

      # Test string representation
      string_repr = request_context.to_s
      expect(string_repr).to include("RequestContext")
      expect(string_repr).to include("method=STDIO")
      expect(string_repr).to include("path=/")

      # Test inspect representation
      inspect_repr = request_context.inspect
      expect(inspect_repr).to include("VectorMCP::RequestContext")
      expect(inspect_repr).to include("method=\"STDIO\"")
      expect(inspect_repr).to include("path=\"/\"")
    end
  end

  describe "error handling and edge cases" do
    it "handles session creation failures gracefully" do
      # Mock server/transport failure
      allow(server).to receive(:logger).and_raise(StandardError, "Server error")

      expect do
        session_manager.get_global_session
      end.to raise_error(StandardError, "Server error")
    end

    it "maintains context integrity during concurrent access" do
      # Simulate concurrent access to global session
      sessions = []
      threads = []

      5.times do
        threads << Thread.new do
          sessions << session_manager.get_or_create_global_session
        end
      end

      threads.each(&:join)

      # Verify all threads got the same session
      expect(sessions.uniq.length).to eq(1)

      # Verify context is consistent
      sessions.each do |session|
        context = session.context.request_context
        expect(context.method).to eq("STDIO")
        expect(context.path).to eq("/")
        expect(context.metadata("transport_type")).to eq("stdio")
      end
    end

    it "preserves context through session manager operations" do
      session = session_manager.get_global_session
      original_context = session.context.request_context

      # Perform various session manager operations
      retrieved_session = session_manager.get_session(session.id)
      all_sessions = session_manager.get_all_sessions

      # Verify context is preserved
      expect(retrieved_session.context.request_context).to eq(original_context)
      expect(all_sessions.first.context.request_context).to eq(original_context)
    end
  end
end
