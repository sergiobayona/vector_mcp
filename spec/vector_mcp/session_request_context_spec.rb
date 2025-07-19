# frozen_string_literal: true

require "spec_helper"

RSpec.describe VectorMCP::Session, "request context integration" do
  let(:server) { instance_double(VectorMCP::Server, logger: logger) }
  let(:logger) { instance_double(Logger, info: nil) }
  let(:transport) { instance_double(VectorMCP::Transport::Base) }

  describe "#initialize with request_context" do
    it "initializes with default empty request context" do
      session = described_class.new(server, transport)

      expect(session.request_context).to be_a(VectorMCP::RequestContext)
      expect(session.request_context.headers).to eq({})
      expect(session.request_context.params).to eq({})
    end

    it "initializes with RequestContext object" do
      context = VectorMCP::RequestContext.new(
        headers: { "Authorization" => "Bearer token" },
        params: { "key" => "value" }
      )

      session = described_class.new(server, transport, request_context: context)

      expect(session.request_context).to eq(context)
      expect(session.request_context.header("Authorization")).to eq("Bearer token")
      expect(session.request_context.param("key")).to eq("value")
    end

    it "initializes with Hash context" do
      context_hash = {
        headers: { "X-API-Key" => "secret" },
        params: { "id" => "123" },
        method: "POST",
        path: "/api/test"
      }

      session = described_class.new(server, transport, request_context: context_hash)

      expect(session.request_context).to be_a(VectorMCP::RequestContext)
      expect(session.request_context.header("X-API-Key")).to eq("secret")
      expect(session.request_context.param("id")).to eq("123")
      expect(session.request_context.method).to eq("POST")
      expect(session.request_context.path).to eq("/api/test")
    end
  end

  describe "#set_request_context" do
    let(:session) { described_class.new(server, transport) }

    it "sets context with RequestContext object" do
      context = VectorMCP::RequestContext.new(
        headers: { "Content-Type" => "application/json" },
        params: { "format" => "json" }
      )

      result = session.set_request_context(context)

      expect(result).to eq(context)
      expect(session.request_context).to eq(context)
    end

    it "sets context with Hash" do
      context_hash = {
        headers: { "User-Agent" => "TestClient" },
        params: { "version" => "1.0" },
        method: "GET",
        path: "/status"
      }

      result = session.set_request_context(context_hash)

      expect(result).to be_a(VectorMCP::RequestContext)
      expect(session.request_context.header("User-Agent")).to eq("TestClient")
      expect(session.request_context.param("version")).to eq("1.0")
      expect(session.request_context.method).to eq("GET")
      expect(session.request_context.path).to eq("/status")
    end

    it "raises error for invalid context type" do
      expect do
        session.set_request_context("invalid")
      end.to raise_error(ArgumentError, /Request context must be a RequestContext or Hash/)
    end
  end

  describe "#update_request_context" do
    let(:session) do
      described_class.new(
        server,
        transport,
        request_context: {
          headers: { "Authorization" => "Bearer token" },
          params: { "page" => "1" },
          method: "GET",
          path: "/users"
        }
      )
    end

    it "updates context with new attributes" do
      result = session.update_request_context(
        headers: { "Authorization" => "Bearer newtoken", "X-Version" => "2.0" },
        params: { "page" => "2", "limit" => "50" }
      )

      expect(result).to be_a(VectorMCP::RequestContext)
      expect(session.request_context.header("Authorization")).to eq("Bearer newtoken")
      expect(session.request_context.header("X-Version")).to eq("2.0")
      expect(session.request_context.param("page")).to eq("2")
      expect(session.request_context.param("limit")).to eq("50")
      expect(session.request_context.method).to eq("GET") # preserved
      expect(session.request_context.path).to eq("/users") # preserved
    end

    it "preserves existing attributes when not overridden" do
      session.update_request_context(headers: { "X-Custom" => "value" })

      expect(session.request_context.header("Authorization")).to eq("Bearer token")
      expect(session.request_context.header("X-Custom")).to eq("value")
      expect(session.request_context.param("page")).to eq("1")
    end
  end

  describe "convenience methods" do
    let(:session) do
      described_class.new(
        server,
        transport,
        request_context: {
          headers: { "Authorization" => "Bearer token", "X-API-Key" => "secret" },
          params: { "api_key" => "param_secret", "format" => "json" }
        }
      )
    end

    describe "#has_request_headers?" do
      it "returns true when headers are present" do
        expect(session.has_request_headers?).to be true
      end

      it "returns false when headers are empty" do
        empty_session = described_class.new(server, transport)
        expect(empty_session.has_request_headers?).to be false
      end
    end

    describe "#has_request_params?" do
      it "returns true when params are present" do
        expect(session.has_request_params?).to be true
      end

      it "returns false when params are empty" do
        empty_session = described_class.new(server, transport)
        expect(empty_session.has_request_params?).to be false
      end
    end

    describe "#request_header" do
      it "returns header value when present" do
        expect(session.request_header("Authorization")).to eq("Bearer token")
        expect(session.request_header("X-API-Key")).to eq("secret")
      end

      it "returns nil when header is not present" do
        expect(session.request_header("Missing-Header")).to be_nil
      end
    end

    describe "#request_param" do
      it "returns param value when present" do
        expect(session.request_param("api_key")).to eq("param_secret")
        expect(session.request_param("format")).to eq("json")
      end

      it "returns nil when param is not present" do
        expect(session.request_param("missing_param")).to be_nil
      end
    end
  end

  describe "integration with server initialization" do
    let(:session) do
      described_class.new(
        server,
        transport,
        request_context: {
          headers: { "User-Agent" => "TestClient/1.0" },
          params: { "version" => "1.0" },
          method: "POST",
          path: "/initialize"
        }
      )
    end

    before do
      allow(server).to receive(:protocol_version).and_return("2024-11-05")
      allow(server).to receive(:server_info).and_return({ name: "TestServer", version: "1.0.0" })
      allow(server).to receive(:server_capabilities).and_return({ tools: {} })
    end

    it "preserves request context after initialization" do
      params = {
        "protocolVersion" => "2024-11-05",
        "clientInfo" => { "name" => "TestClient", "version" => "1.0.0" },
        "capabilities" => { "tools" => {} }
      }

      session.initialize!(params)

      expect(session.request_context.header("User-Agent")).to eq("TestClient/1.0")
      expect(session.request_context.param("version")).to eq("1.0")
      expect(session.request_context.method).to eq("POST")
      expect(session.request_context.path).to eq("/initialize")
    end
  end

  describe "backward compatibility" do
    it "maintains existing session functionality" do
      session = described_class.new(server, transport, id: "test-session")

      expect(session.id).to eq("test-session")
      expect(session.server).to eq(server)
      expect(session.transport).to eq(transport)
      expect(session.initialized?).to be false
      expect(session.data).to eq({})
    end

    it "allows setting custom session data" do
      session = described_class.new(server, transport)
      session.data[:custom_key] = "custom_value"

      expect(session.data[:custom_key]).to eq("custom_value")
    end
  end
end
