# frozen_string_literal: true

require "spec_helper"

RSpec.describe VectorMCP::Handlers::Core, "context integration" do
  describe ".extract_request_from_session" do
    let(:server) { instance_double(VectorMCP::Server, logger: logger) }
    let(:logger) { instance_double(Logger, info: nil, warn: nil) }
    let(:transport) { instance_double(VectorMCP::Transport::Base) }

    context "with new public interface" do
      let(:session) do
        VectorMCP::Session.new(
          server,
          transport,
          id: "test-session",
          request_context: {
            headers: {
              "Authorization" => "Bearer token123",
              "X-API-Key" => "secret456",
              "Content-Type" => "application/json"
            },
            params: {
              "api_key" => "param_secret",
              "format" => "json",
              "limit" => "100"
            },
            method: "POST",
            path: "/api/test",
            transport_metadata: {
              "transport_type" => "http_stream",
              "remote_addr" => "127.0.0.1"
            }
          }
        )
      end

      it "extracts request context using public interface" do
        result = described_class.send(:extract_request_from_session, session)

        expect(result).to be_a(Hash)
        expect(result[:headers]).to eq({
                                         "Authorization" => "Bearer token123",
                                         "X-API-Key" => "secret456",
                                         "Content-Type" => "application/json"
                                       })
        expect(result[:params]).to eq({
                                        "api_key" => "param_secret",
                                        "format" => "json",
                                        "limit" => "100"
                                      })
        expect(result[:session_id]).to eq("test-session")
      end

      it "handles session with minimal context" do
        minimal_session = VectorMCP::Session.new(
          server,
          transport,
          id: "minimal-session",
          request_context: VectorMCP::RequestContext.minimal("stdio")
        )

        result = described_class.send(:extract_request_from_session, minimal_session)

        expect(result).to be_a(Hash)
        expect(result[:headers]).to eq({})
        expect(result[:params]).to eq({})
        expect(result[:session_id]).to eq("minimal-session")
      end

      it "handles session with empty context" do
        empty_session = VectorMCP::Session.new(server, transport, id: "empty-session")

        result = described_class.send(:extract_request_from_session, empty_session)

        expect(result).to be_a(Hash)
        expect(result[:headers]).to eq({})
        expect(result[:params]).to eq({})
        expect(result[:session_id]).to eq("empty-session")
      end

      it "does not log deprecation warnings for new interface" do
        allow(VectorMCP).to receive(:logger_for).and_return(logger)

        described_class.send(:extract_request_from_session, session)

        expect(logger).not_to have_received(:warn)
      end
    end

    context "with invalid session interface" do
      let(:legacy_session) do
        # Create a session object that doesn't have request_context
        session = instance_double(VectorMCP::Session)
        allow(session).to receive(:respond_to?).with(:request_context).and_return(false)
        allow(session).to receive(:id).and_return("invalid-session")
        session
      end

      it "raises error for sessions without request_context" do
        expect do
          described_class.send(:extract_request_from_session, legacy_session)
        end.to raise_error(VectorMCP::InternalError, /Session missing request_context/)
      end

      it "raises error for sessions with nil request_context" do
        session_with_nil_context = instance_double(VectorMCP::Session)
        allow(session_with_nil_context).to receive(:respond_to?).with(:request_context).and_return(true)
        allow(session_with_nil_context).to receive(:request_context).and_return(nil)
        allow(session_with_nil_context).to receive(:id).and_return("nil-context-session")

        expect do
          described_class.send(:extract_request_from_session, session_with_nil_context)
        end.to raise_error(VectorMCP::InternalError, /Session missing request_context/)
      end
    end

    context "with edge cases" do
      it "handles session with valid empty request context" do
        # Normal session with empty but valid request context
        session_with_empty_context = VectorMCP::Session.new(server, transport, id: "empty-context-session")

        result = described_class.send(:extract_request_from_session, session_with_empty_context)

        expect(result).to be_a(Hash)
        expect(result[:headers]).to eq({})
        expect(result[:params]).to eq({})
        expect(result[:session_id]).to eq("empty-context-session")
      end
    end
  end

  describe "integration with security workflows" do
    let(:server) { instance_double(VectorMCP::Server, logger: logger) }
    let(:logger) { instance_double(Logger, info: nil, warn: nil) }
    let(:transport) { instance_double(VectorMCP::Transport::Base) }

    context "with HTTP stream transport session" do
      let(:http_session) do
        VectorMCP::Session.new(
          server,
          transport,
          id: "http-session",
          request_context: VectorMCP::RequestContext.from_rack_env({
                                                                     "REQUEST_METHOD" => "POST",
                                                                     "PATH_INFO" => "/api/tools/call",
                                                                     "QUERY_STRING" => "api_key=test123",
                                                                     "HTTP_AUTHORIZATION" => "Bearer token123",
                                                                     "HTTP_X_API_KEY" => "secret456",
                                                                     "HTTP_USER_AGENT" => "TestClient/1.0",
                                                                     "REMOTE_ADDR" => "127.0.0.1"
                                                                   }, "http_stream")
        )
      end

      it "extracts context suitable for security middleware" do
        result = described_class.send(:extract_request_from_session, http_session)

        expect(result[:headers]["Authorization"]).to eq("Bearer token123")
        expect(result[:headers]["X-API-Key"]).to eq("secret456")
        expect(result[:headers]["User-Agent"]).to eq("TestClient/1.0")
        expect(result[:params]["api_key"]).to eq("test123")
        expect(result[:session_id]).to eq("http-session")
      end

      it "provides context that works with API key authentication" do
        result = described_class.send(:extract_request_from_session, http_session)

        # Simulate API key extraction like security middleware would do
        api_key_from_header = result[:headers]["X-API-Key"]
        api_key_from_param = result[:params]["api_key"]

        expect(api_key_from_header).to eq("secret456")
        expect(api_key_from_param).to eq("test123")
      end

      it "provides context that works with bearer token authentication" do
        result = described_class.send(:extract_request_from_session, http_session)

        # Simulate bearer token extraction like security middleware would do
        auth_header = result[:headers]["Authorization"]
        bearer_token = auth_header&.start_with?("Bearer ") ? auth_header[7..] : nil

        expect(bearer_token).to eq("token123")
      end
    end

    context "with SSE transport session" do
      let(:sse_session) do
        VectorMCP::Session.new(
          server,
          transport,
          id: "sse-session",
          request_context: VectorMCP::RequestContext.from_rack_env({
                                                                     "REQUEST_METHOD" => "GET",
                                                                     "PATH_INFO" => "/sse",
                                                                     "QUERY_STRING" => "session_id=sse-123&auth_token=sse-token",
                                                                     "HTTP_ACCEPT" => "text/event-stream",
                                                                     "HTTP_X_SSE_AUTH" => "sse-secret",
                                                                     "REMOTE_ADDR" => "192.168.1.100"
                                                                   }, "sse")
        )
      end

      it "extracts context suitable for SSE-specific authentication" do
        result = described_class.send(:extract_request_from_session, sse_session)

        expect(result[:headers]["Accept"]).to eq("text/event-stream")
        expect(result[:headers]["X-Sse-Auth"]).to eq("sse-secret")
        expect(result[:params]["session_id"]).to eq("sse-123")
        expect(result[:params]["auth_token"]).to eq("sse-token")
        expect(result[:session_id]).to eq("sse-session")
      end
    end

    context "with stdio transport session" do
      let(:stdio_session) do
        VectorMCP::Session.new(
          server,
          transport,
          id: "stdio-session",
          request_context: VectorMCP::RequestContext.minimal("stdio")
        )
      end

      it "extracts minimal context for stdio transport" do
        result = described_class.send(:extract_request_from_session, stdio_session)

        expect(result[:headers]).to eq({})
        expect(result[:params]).to eq({})
        expect(result[:session_id]).to eq("stdio-session")
      end

      it "works with authentication disabled scenarios" do
        result = described_class.send(:extract_request_from_session, stdio_session)

        # Should not have authentication headers (typical for stdio)
        expect(result[:headers]["Authorization"]).to be_nil
        expect(result[:headers]["X-API-Key"]).to be_nil
        expect(result[:params]["api_key"]).to be_nil
      end
    end
  end

  describe "performance and caching considerations" do
    let(:server) { instance_double(VectorMCP::Server, logger: logger) }
    let(:logger) { instance_double(Logger, info: nil, warn: nil) }
    let(:transport) { instance_double(VectorMCP::Transport::Base) }

    it "efficiently accesses context without repeated computation" do
      session = VectorMCP::Session.new(
        server,
        transport,
        id: "performance-test",
        request_context: {
          headers: { "X-Performance-Test" => "value" },
          params: { "performance_param" => "test" }
        }
      )

      # Multiple calls should be efficient
      result1 = described_class.send(:extract_request_from_session, session)
      result2 = described_class.send(:extract_request_from_session, session)

      expect(result1).to eq(result2)
      expect(result1[:headers]["X-Performance-Test"]).to eq("value")
      expect(result1[:params]["performance_param"]).to eq("test")
    end

    it "handles large context data efficiently" do
      large_headers = {}
      large_params = {}

      # Create large context data
      100.times do |i|
        large_headers["X-Large-Header-#{i}"] = "value-#{i}"
        large_params["large_param_#{i}"] = "param_value_#{i}"
      end

      session = VectorMCP::Session.new(
        server,
        transport,
        id: "large-context-test",
        request_context: {
          headers: large_headers,
          params: large_params
        }
      )

      result = described_class.send(:extract_request_from_session, session)

      expect(result[:headers].keys.length).to eq(100)
      expect(result[:params].keys.length).to eq(100)
      expect(result[:headers]["X-Large-Header-50"]).to eq("value-50")
      expect(result[:params]["large_param_50"]).to eq("param_value_50")
    end
  end
end
