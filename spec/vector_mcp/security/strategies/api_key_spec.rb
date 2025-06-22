# frozen_string_literal: true

require "spec_helper"

RSpec.describe VectorMCP::Security::Strategies::ApiKey do
  let(:api_key_strategy) { described_class.new(keys: %w[valid-key-1 valid-key-2]) }

  describe "#initialize" do
    it "initializes with provided keys" do
      expect(api_key_strategy.valid_keys).to include("valid-key-1", "valid-key-2")
    end

    it "initializes with empty keys by default" do
      strategy = described_class.new
      expect(strategy.valid_keys).to be_empty
    end
  end

  describe "#add_key" do
    it "adds a valid API key" do
      api_key_strategy.add_key("new-key")
      expect(api_key_strategy.valid_keys).to include("new-key")
    end
  end

  describe "#remove_key" do
    it "removes an API key" do
      api_key_strategy.remove_key("valid-key-1")
      expect(api_key_strategy.valid_keys).not_to include("valid-key-1")
    end
  end

  describe "#authenticate" do
    context "with X-API-Key header" do
      it "authenticates valid key" do
        request = { headers: { "X-API-Key" => "valid-key-1" } }
        result = api_key_strategy.authenticate(request)

        expect(result).to be_truthy
        expect(result[:api_key]).to eq("valid-key-1")
        expect(result[:strategy]).to eq("api_key")
        expect(result[:authenticated_at]).to be_a(Time)
      end

      it "rejects invalid key" do
        request = { headers: { "X-API-Key" => "invalid-key" } }
        result = api_key_strategy.authenticate(request)

        expect(result).to be false
      end
    end

    context "with Authorization Bearer header" do
      it "authenticates valid bearer token" do
        request = { headers: { "Authorization" => "Bearer valid-key-1" } }
        result = api_key_strategy.authenticate(request)

        expect(result).to be_truthy
        expect(result[:api_key]).to eq("valid-key-1")
      end

      it "rejects invalid bearer token" do
        request = { headers: { "Authorization" => "Bearer invalid-key" } }
        result = api_key_strategy.authenticate(request)

        expect(result).to be false
      end
    end

    context "with Authorization API-Key header" do
      it "authenticates valid API-Key" do
        request = { headers: { "Authorization" => "API-Key valid-key-1" } }
        result = api_key_strategy.authenticate(request)

        expect(result).to be_truthy
        expect(result[:api_key]).to eq("valid-key-1")
      end
    end

    context "with query parameter" do
      it "authenticates valid api_key parameter" do
        request = { params: { "api_key" => "valid-key-1" } }
        result = api_key_strategy.authenticate(request)

        expect(result).to be_truthy
        expect(result[:api_key]).to eq("valid-key-1")
      end

      it "authenticates valid apikey parameter" do
        request = { params: { "apikey" => "valid-key-1" } }
        result = api_key_strategy.authenticate(request)

        expect(result).to be_truthy
        expect(result[:api_key]).to eq("valid-key-1")
      end
    end

    context "with case insensitive headers" do
      it "handles lowercase headers" do
        request = { headers: { "x-api-key" => "valid-key-1" } }
        result = api_key_strategy.authenticate(request)

        expect(result).to be_truthy
        expect(result[:api_key]).to eq("valid-key-1")
      end

      it "handles lowercase authorization header" do
        request = { headers: { "authorization" => "Bearer valid-key-1" } }
        result = api_key_strategy.authenticate(request)

        expect(result).to be_truthy
        expect(result[:api_key]).to eq("valid-key-1")
      end
    end

    context "with no authentication" do
      it "rejects request with no headers" do
        request = { headers: {}, params: {} }
        result = api_key_strategy.authenticate(request)

        expect(result).to be false
      end

      it "rejects request with empty key" do
        request = { headers: { "X-API-Key" => "" } }
        result = api_key_strategy.authenticate(request)

        expect(result).to be false
      end

      it "rejects request with nil key" do
        request = { headers: { "X-API-Key" => nil } }
        result = api_key_strategy.authenticate(request)

        expect(result).to be false
      end
    end
  end

  describe "#configured?" do
    it "returns true when keys are present" do
      expect(api_key_strategy.configured?).to be true
    end

    it "returns false when no keys" do
      strategy = described_class.new
      expect(strategy.configured?).to be false
    end
  end

  describe "#key_count" do
    it "returns number of configured keys" do
      expect(api_key_strategy.key_count).to eq(2)
    end
  end
end
