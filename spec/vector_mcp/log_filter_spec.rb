# frozen_string_literal: true

require "spec_helper"

RSpec.describe VectorMCP::LogFilter do
  describe ".filter_hash" do
    it "redacts known sensitive keys" do
      input = {
        "authorization" => "Bearer secret-token",
        "x-api-key" => "my-api-key",
        "content-type" => "application/json"
      }

      result = described_class.filter_hash(input)

      expect(result["authorization"]).to eq("[FILTERED]")
      expect(result["x-api-key"]).to eq("[FILTERED]")
      expect(result["content-type"]).to eq("application/json")
    end

    it "handles symbol keys case-insensitively" do
      input = { Authorization: "Bearer token", password: "secret123" }
      result = described_class.filter_hash(input)

      expect(result[:Authorization]).to eq("[FILTERED]")
      expect(result[:password]).to eq("[FILTERED]")
    end

    it "deep-redacts nested hashes" do
      input = {
        "headers" => {
          "Authorization" => "Bearer nested-token",
          "Accept" => "application/json"
        },
        "safe" => "value"
      }

      result = described_class.filter_hash(input)

      expect(result["headers"]["Authorization"]).to eq("[FILTERED]")
      expect(result["headers"]["Accept"]).to eq("application/json")
      expect(result["safe"]).to eq("value")
    end

    it "filters token patterns in string values" do
      input = { "message" => "Auth is Bearer my-secret-key here" }
      result = described_class.filter_hash(input)

      expect(result["message"]).to include("Bearer [FILTERED]")
      expect(result["message"]).not_to include("my-secret-key")
    end

    it "returns non-hash input unchanged" do
      expect(described_class.filter_hash("string")).to eq("string")
      expect(described_class.filter_hash(nil)).to be_nil
    end

    it "does not modify the original hash" do
      input = { "api_key" => "original-key" }
      described_class.filter_hash(input)
      expect(input["api_key"]).to eq("original-key")
    end
  end

  describe ".filter_string" do
    it "redacts Bearer tokens" do
      result = described_class.filter_string("Authorization: Bearer eyJhbGciOiJ...")
      expect(result).to include("Bearer [FILTERED]")
      expect(result).not_to include("eyJhbGciOiJ")
    end

    it "redacts Basic auth" do
      result = described_class.filter_string("Basic dXNlcjpwYXNz")
      expect(result).to include("Basic [FILTERED]")
      expect(result).not_to include("dXNlcjpwYXNz")
    end

    it "redacts API-Key scheme" do
      result = described_class.filter_string("API-Key my-secret-key")
      expect(result).to include("API-Key [FILTERED]")
      expect(result).not_to include("my-secret-key")
    end

    it "leaves non-sensitive strings unchanged" do
      input = "This is a normal log message"
      expect(described_class.filter_string(input)).to eq(input)
    end

    it "returns non-string input unchanged" do
      expect(described_class.filter_string(42)).to eq(42)
      expect(described_class.filter_string(nil)).to be_nil
    end
  end
end
