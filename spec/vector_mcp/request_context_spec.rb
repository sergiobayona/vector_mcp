# frozen_string_literal: true

require "spec_helper"

RSpec.describe VectorMCP::RequestContext do
  describe "#initialize" do
    it "creates a context with default values" do
      context = described_class.new
      
      expect(context.headers).to eq({})
      expect(context.params).to eq({})
      expect(context.method).to be_nil
      expect(context.path).to be_nil
      expect(context.transport_metadata).to eq({})
    end

    it "creates a context with provided values" do
      context = described_class.new(
        headers: { "Content-Type" => "application/json" },
        params: { "key" => "value" },
        method: "POST",
        path: "/api/test",
        transport_metadata: { transport_type: "http" }
      )
      
      expect(context.headers).to eq({ "Content-Type" => "application/json" })
      expect(context.params).to eq({ "key" => "value" })
      expect(context.method).to eq("POST")
      expect(context.path).to eq("/api/test")
      expect(context.transport_metadata).to eq({ "transport_type" => "http" })
    end

    it "normalizes and freezes data" do
      context = described_class.new(
        headers: { :content_type => "application/json" },
        params: { :api_key => "secret" }
      )
      
      expect(context.headers).to eq({ "content_type" => "application/json" })
      expect(context.params).to eq({ "api_key" => "secret" })
      expect(context.headers).to be_frozen
      expect(context.params).to be_frozen
    end
  end

  describe "#to_h" do
    it "returns a hash representation" do
      context = described_class.new(
        headers: { "Authorization" => "Bearer token" },
        params: { "id" => "123" },
        method: "GET",
        path: "/users",
        transport_metadata: { transport_type: "sse" }
      )
      
      expected = {
        headers: { "Authorization" => "Bearer token" },
        params: { "id" => "123" },
        method: "GET",
        path: "/users",
        transport_metadata: { "transport_type" => "sse" }
      }
      
      expect(context.to_h).to eq(expected)
    end
  end

  describe "#has_headers?" do
    it "returns true when headers are present" do
      context = described_class.new(headers: { "X-API-Key" => "test" })
      expect(context.has_headers?).to be true
    end

    it "returns false when headers are empty" do
      context = described_class.new(headers: {})
      expect(context.has_headers?).to be false
    end
  end

  describe "#has_params?" do
    it "returns true when params are present" do
      context = described_class.new(params: { "filter" => "active" })
      expect(context.has_params?).to be true
    end

    it "returns false when params are empty" do
      context = described_class.new(params: {})
      expect(context.has_params?).to be false
    end
  end

  describe "#header" do
    let(:context) do
      described_class.new(headers: { "Authorization" => "Bearer token", "X-API-Key" => "secret" })
    end

    it "returns header value when present" do
      expect(context.header("Authorization")).to eq("Bearer token")
      expect(context.header("X-API-Key")).to eq("secret")
    end

    it "returns nil when header is not present" do
      expect(context.header("Missing-Header")).to be_nil
    end
  end

  describe "#param" do
    let(:context) do
      described_class.new(params: { "api_key" => "secret", "limit" => "10" })
    end

    it "returns param value when present" do
      expect(context.param("api_key")).to eq("secret")
      expect(context.param("limit")).to eq("10")
    end

    it "returns nil when param is not present" do
      expect(context.param("missing_param")).to be_nil
    end
  end

  describe "#metadata" do
    let(:context) do
      described_class.new(transport_metadata: { "transport_type" => "http", "version" => "1.0" })
    end

    it "returns metadata value when present" do
      expect(context.metadata("transport_type")).to eq("http")
      expect(context.metadata("version")).to eq("1.0")
    end

    it "returns nil when metadata is not present" do
      expect(context.metadata("missing_key")).to be_nil
    end

    it "accepts symbol keys" do
      expect(context.metadata(:transport_type)).to eq("http")
    end
  end

  describe "#http_transport?" do
    it "returns true when method and path are present" do
      context = described_class.new(method: "GET", path: "/api")
      expect(context.http_transport?).to be true
    end

    it "returns false when method is missing" do
      context = described_class.new(path: "/api")
      expect(context.http_transport?).to be false
    end

    it "returns false when path is missing" do
      context = described_class.new(method: "GET")
      expect(context.http_transport?).to be false
    end
  end

  describe ".minimal" do
    it "creates a minimal context for non-HTTP transports" do
      context = described_class.minimal("stdio")
      
      expect(context.headers).to eq({})
      expect(context.params).to eq({})
      expect(context.method).to eq("STDIO")
      expect(context.path).to eq("/")
      expect(context.metadata("transport_type")).to eq("stdio")
    end
  end

  describe ".from_rack_env" do
    let(:rack_env) do
      {
        "REQUEST_METHOD" => "POST",
        "PATH_INFO" => "/api/test",
        "QUERY_STRING" => "key=value&filter=active",
        "HTTP_AUTHORIZATION" => "Bearer token123",
        "HTTP_X_API_KEY" => "secret",
        "CONTENT_TYPE" => "application/json",
        "REMOTE_ADDR" => "127.0.0.1",
        "HTTP_USER_AGENT" => "TestClient/1.0"
      }
    end

    it "creates context from Rack environment" do
      context = described_class.from_rack_env(rack_env, "http_stream")
      
      expect(context.method).to eq("POST")
      expect(context.path).to eq("/api/test")
      expect(context.header("Authorization")).to eq("Bearer token123")
      expect(context.header("X-API-Key")).to eq("secret")
      expect(context.param("key")).to eq("value")
      expect(context.param("filter")).to eq("active")
      expect(context.metadata("transport_type")).to eq("http_stream")
      expect(context.metadata("remote_addr")).to eq("127.0.0.1")
      expect(context.metadata("user_agent")).to eq("TestClient/1.0")
    end
  end

  describe "#to_s" do
    it "returns a readable string representation" do
      context = described_class.new(
        method: "GET",
        path: "/api",
        headers: { "Authorization" => "Bearer token" },
        params: { "id" => "123" }
      )
      
      result = context.to_s
      expect(result).to include("RequestContext")
      expect(result).to include("method=GET")
      expect(result).to include("path=/api")
      expect(result).to include("headers=1")
      expect(result).to include("params=1")
    end
  end

  describe "#inspect" do
    it "returns a detailed string representation" do
      context = described_class.new(method: "POST", path: "/test")
      
      result = context.inspect
      expect(result).to include("VectorMCP::RequestContext")
      expect(result).to include("method=\"POST\"")
      expect(result).to include("path=\"/test\"")
    end
  end

  describe "data normalization" do
    it "handles nil values in headers" do
      context = described_class.new(headers: { "X-Test" => nil })
      expect(context.header("X-Test")).to eq("")
    end

    it "handles nil values in params" do
      context = described_class.new(params: { "param" => nil })
      expect(context.param("param")).to eq("")
    end

    it "converts non-string values to strings" do
      context = described_class.new(
        headers: { "X-Count" => 42 },
        params: { "active" => true }
      )
      
      expect(context.header("X-Count")).to eq("42")
      expect(context.param("active")).to eq("true")
    end

    it "handles non-hash inputs gracefully" do
      context = described_class.new(
        headers: "invalid",
        params: nil,
        transport_metadata: []
      )
      
      expect(context.headers).to eq({})
      expect(context.params).to eq({})
      expect(context.transport_metadata).to eq({})
    end
  end
end