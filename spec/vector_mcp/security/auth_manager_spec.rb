# frozen_string_literal: true

require "spec_helper"

RSpec.describe VectorMCP::Security::AuthManager do
  let(:auth_manager) { described_class.new }

  describe "#initialize" do
    it "starts disabled with no strategies" do
      expect(auth_manager.enabled).to be false
      expect(auth_manager.strategies).to be_empty
      expect(auth_manager.default_strategy).to be_nil
    end
  end

  describe "#enable!" do
    it "enables authentication with default strategy" do
      auth_manager.enable!
      expect(auth_manager.enabled).to be true
      expect(auth_manager.default_strategy).to eq(:api_key)
    end

    it "allows custom default strategy" do
      auth_manager.enable!(default_strategy: :custom)
      expect(auth_manager.default_strategy).to eq(:custom)
    end
  end

  describe "#disable!" do
    it "disables authentication" do
      auth_manager.enable!
      auth_manager.disable!
      expect(auth_manager.enabled).to be false
      expect(auth_manager.default_strategy).to be_nil
    end
  end

  describe "#add_strategy" do
    let(:strategy) { instance_double("Strategy") }

    it "adds a strategy" do
      auth_manager.add_strategy(:test, strategy)
      expect(auth_manager.strategies[:test]).to eq(strategy)
    end
  end

  describe "#authenticate" do
    let(:request) { { headers: { "X-API-Key" => "test-key" } } }
    let(:strategy) { instance_double("Strategy") }

    context "when disabled" do
      it "returns success without authentication" do
        result = auth_manager.authenticate(request)
        expect(result[:authenticated]).to be true
        expect(result[:user]).to be_nil
      end
    end

    context "when enabled" do
      before do
        auth_manager.enable!
        auth_manager.add_strategy(:api_key, strategy)
      end

      it "authenticates using default strategy" do
        allow(strategy).to receive(:authenticate).with(request).and_return({ user_id: 123 })

        result = auth_manager.authenticate(request)
        expect(result[:authenticated]).to be true
        expect(result[:user]).to eq({ user_id: 123 })
      end

      it "handles authentication failure" do
        allow(strategy).to receive(:authenticate).with(request).and_return(false)

        result = auth_manager.authenticate(request)
        expect(result[:authenticated]).to be false
        expect(result[:error]).to eq("Authentication failed")
      end

      it "handles unknown strategy" do
        result = auth_manager.authenticate(request, strategy: :unknown)
        expect(result[:authenticated]).to be false
        expect(result[:error]).to include("Unknown strategy")
      end

      it "handles strategy errors" do
        allow(strategy).to receive(:authenticate).and_raise(StandardError, "Auth error")

        result = auth_manager.authenticate(request)
        expect(result[:authenticated]).to be false
        expect(result[:error]).to include("Authentication error")
      end
    end
  end

  describe "#required?" do
    it "returns false when disabled" do
      expect(auth_manager.required?).to be false
    end

    it "returns true when enabled" do
      auth_manager.enable!
      expect(auth_manager.required?).to be true
    end
  end

  describe "#available_strategies" do
    it "returns empty array initially" do
      expect(auth_manager.available_strategies).to eq([])
    end

    it "returns strategy names after adding" do
      strategy = instance_double("Strategy")
      auth_manager.add_strategy(:test, strategy)
      expect(auth_manager.available_strategies).to eq([:test])
    end
  end
end
