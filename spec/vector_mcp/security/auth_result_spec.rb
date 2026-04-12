# frozen_string_literal: true

require "spec_helper"

RSpec.describe VectorMCP::Security::AuthResult do
  describe "#initialize" do
    it "creates an authenticated result with all fields" do
      time = Time.now
      result = described_class.new(authenticated: true, user: { id: 1 }, strategy: "api_key", authenticated_at: time)

      expect(result.authenticated?).to be true
      expect(result.user).to eq({ id: 1 })
      expect(result.strategy).to eq("api_key")
      expect(result.authenticated_at).to eq(time)
    end

    it "defaults authenticated_at to now when authenticated" do
      result = described_class.new(authenticated: true)

      expect(result.authenticated_at).to be_a(Time)
      expect(result.authenticated_at).to be_within(1).of(Time.now)
    end

    it "leaves authenticated_at nil when not authenticated" do
      result = described_class.new(authenticated: false)

      expect(result.authenticated_at).to be_nil
    end

    it "is frozen" do
      result = described_class.new(authenticated: true)

      expect(result).to be_frozen
    end
  end

  describe ".success" do
    it "creates an authenticated result with user and strategy" do
      result = described_class.success(user: "user123", strategy: "jwt")

      expect(result.authenticated?).to be true
      expect(result.user).to eq("user123")
      expect(result.strategy).to eq("jwt")
      expect(result.authenticated_at).to be_a(Time)
    end

    it "accepts a custom authenticated_at" do
      time = Time.now - 3600
      result = described_class.success(user: nil, strategy: "custom", authenticated_at: time)

      expect(result.authenticated_at).to eq(time)
    end

    it "supports nil user for authenticated-without-user-object scenarios" do
      result = described_class.success(user: nil, strategy: "custom")

      expect(result.authenticated?).to be true
      expect(result.user).to be_nil
      expect(result.strategy).to eq("custom")
    end
  end

  describe ".failure" do
    it "creates an unauthenticated result" do
      result = described_class.failure

      expect(result.authenticated?).to be false
      expect(result.user).to be_nil
      expect(result.strategy).to be_nil
      expect(result.authenticated_at).to be_nil
    end
  end

  describe ".passthrough" do
    it "creates an authenticated result with no user or strategy" do
      result = described_class.passthrough

      expect(result.authenticated?).to be true
      expect(result.user).to be_nil
      expect(result.strategy).to be_nil
      expect(result.authenticated_at).to be_a(Time)
    end
  end
end
