# frozen_string_literal: true

require "spec_helper"

RSpec.describe VectorMCP::Session, "request context integration" do
  let(:server) { instance_double(VectorMCP::Server, logger: logger) }
  let(:logger) { instance_double(Logger, info: nil) }
  let(:transport) { instance_double(VectorMCP::Transport::Base) }

  describe "removed request-scoped API (0.7)" do
    it "no longer exposes per-request accessors on the session" do
      session = described_class.new(server, transport)

      %i[request_context= update_request_context request_headers? request_params?
         request_header request_param].each do |method_name|
        expect(session).not_to respond_to(method_name)
      end
    end
  end

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
