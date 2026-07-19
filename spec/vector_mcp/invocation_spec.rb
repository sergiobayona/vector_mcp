# frozen_string_literal: true

require "spec_helper"

RSpec.describe VectorMCP::Invocation do
  let(:server) { instance_double(VectorMCP::Server, logger: Logger.new(IO::NULL)) }
  let(:session) { VectorMCP::Session.new(server, nil, id: "session-1") }

  describe "#initialize" do
    it "defaults to the session's stored request context" do
      invocation = described_class.new(session)

      expect(invocation.request_context).to be(session.request_context)
    end

    it "carries its own request context when given one" do
      context = VectorMCP::RequestContext.new(headers: { "X-API-Key" => "k" })
      invocation = described_class.new(session, request_context: context)

      expect(invocation.request_header("X-API-Key")).to eq("k")
      expect(session.request_header("X-API-Key")).to be_nil
    end

    it "coerces hash request contexts" do
      invocation = described_class.new(session, request_context: { headers: { "X-API-Key" => "k" } })

      expect(invocation.request_context).to be_a(VectorMCP::RequestContext)
      expect(invocation.request_header("X-API-Key")).to eq("k")
    end

    it "starts with an anonymous security context" do
      expect(described_class.new(session).security_context.authenticated?).to be(false)
    end
  end

  describe "session delegation" do
    it "delegates identity and session-lived state" do
      invocation = described_class.new(session)

      expect(invocation.id).to eq("session-1")
      expect(invocation.initialized?).to be(false)

      invocation.data[:key] = "value"
      expect(session.data[:key]).to eq("value")
    end
  end

  describe "request-scoped isolation" do
    it "keeps security contexts independent across invocations of one session" do
      invocation_a = described_class.new(session)
      invocation_b = described_class.new(session)

      invocation_a.security_context = VectorMCP::Security::SessionContext.new(
        user: { api_key: "a" }, authenticated: true
      )

      expect(invocation_b.security_context.authenticated?).to be(false)
    end
  end

  describe "security context forwarding" do
    it "exposes the resolved auth API directly, so handlers written against SessionContext keep working" do
      invocation = described_class.new(session)
      invocation.security_context = VectorMCP::Security::SessionContext.new(
        user: { api_key: "k" }, authenticated: true, auth_strategy: "api_key"
      )

      expect(invocation.user).to eq(api_key: "k")
      expect(invocation.authenticated?).to be(true)
      expect(invocation.auth_strategy).to eq("api_key")
      expect(invocation.user_identifier).to eq("k")

      invocation.add_permission("read:resources")
      expect(invocation.can?("read:resources")).to be(true)
      expect(invocation.can_access?(:read, :resources)).to be(true)
    end

    it "forwards to the current security context after reassignment" do
      invocation = described_class.new(session)
      expect(invocation.authenticated?).to be(false)

      invocation.security_context = VectorMCP::Security::SessionContext.new(user: "u", authenticated: true)
      expect(invocation.authenticated?).to be(true)
      expect(invocation.user).to eq("u")
    end
  end

  describe "equality" do
    it "treats invocations of the same session as equal (for subscriber dedup)" do
      invocation_a = described_class.new(session)
      invocation_b = described_class.new(session)

      expect(invocation_a).to eq(invocation_b)
      expect([invocation_a].include?(invocation_b)).to be(true)
    end

    it "treats invocations of different sessions as distinct" do
      other = VectorMCP::Session.new(server, nil, id: "session-2")

      expect(described_class.new(session)).not_to eq(described_class.new(other))
    end
  end
end
