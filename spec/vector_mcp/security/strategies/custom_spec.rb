# frozen_string_literal: true

require "spec_helper"

RSpec.describe VectorMCP::Security::Strategies::Custom do
  describe "#initialize" do
    it "requires a block handler" do
      expect {
        described_class.new
      }.to raise_error(ArgumentError, "Custom authentication strategy requires a block")
    end

    it "accepts a proc handler" do
      handler = proc { |req| { user_id: 123 } }
      strategy = described_class.new(&handler)
      expect(strategy.handler).to eq(handler)
    end
  end

  describe "#authenticate" do
    let(:request) { { headers: { "X-Auth" => "token" } } }

    context "with successful hash result" do
      let(:strategy) do
        described_class.new do |req|
          { user_id: 123, email: "test@example.com" }
        end
      end

      it "returns handler result with strategy metadata" do
        result = strategy.authenticate(request)

        expect(result).to include(
          user_id: 123,
          email: "test@example.com",
          strategy: "custom"
        )
        expect(result[:authenticated_at]).to be_a(Time)
      end
    end

    context "with string result" do
      let(:strategy) do
        described_class.new { |req| "user123" }
      end

      it "wraps string in user field" do
        result = strategy.authenticate(request)

        expect(result).to include(
          user: "user123",
          strategy: "custom"
        )
        expect(result[:authenticated_at]).to be_a(Time)
      end
    end

    context "with false result" do
      let(:strategy) do
        described_class.new { |req| false }
      end

      it "returns false" do
        result = strategy.authenticate(request)
        expect(result).to be false
      end
    end

    context "with nil result" do
      let(:strategy) do
        described_class.new { |req| nil }
      end

      it "returns false" do
        result = strategy.authenticate(request)
        expect(result).to be false
      end
    end

    context "with handler error" do
      let(:strategy) do
        described_class.new { |req| raise StandardError, "Auth error" }
      end

      it "returns false on error" do
        result = strategy.authenticate(request)
        expect(result).to be false
      end
    end
  end

  describe "#configured?" do
    it "returns true when handler is present" do
      strategy = described_class.new { |req| true }
      expect(strategy.configured?).to be true
    end
  end
end