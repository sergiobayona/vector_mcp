# frozen_string_literal: true

require "spec_helper"

RSpec.describe VectorMCP::Security::SessionContext do
  let(:user) { { user_id: 123, email: "test@example.com" } }
  let(:auth_time) { Time.now - 100 }

  describe "#initialize" do
    it "initializes with default values" do
      context = described_class.new

      expect(context.user).to be_nil
      expect(context.authenticated).to be false
      expect(context.auth_strategy).to be_nil
      expect(context.authenticated_at).to be_a(Time)
      expect(context.permissions).to be_empty
    end

    it "initializes with provided values" do
      context = described_class.new(
        user: user,
        authenticated: true,
        auth_strategy: "api_key",
        authenticated_at: auth_time
      )

      expect(context.user).to eq(user)
      expect(context.authenticated).to be true
      expect(context.auth_strategy).to eq("api_key")
      expect(context.authenticated_at).to eq(auth_time)
    end
  end

  describe "#authenticated?" do
    it "returns false for unauthenticated context" do
      context = described_class.new(authenticated: false)

      expect(context.authenticated?).to be false
    end

    it "returns true for authenticated context" do
      context = described_class.new(authenticated: true)

      expect(context.authenticated?).to be true
    end
  end

  describe "#can?" do
    let(:context) { described_class.new }

    it "returns false for permissions not granted" do
      expect(context.can?("read")).to be false
      expect(context.can?(:write)).to be false
    end

    it "returns true for permissions that are granted" do
      context.add_permission("read")
      context.add_permission(:write)

      expect(context.can?("read")).to be true
      expect(context.can?(:write)).to be true
    end
  end

  describe "#can_access?" do
    let(:context) { described_class.new }

    context "with specific permissions" do
      before do
        context.add_permission("read:files")
        context.add_permission("write:configs")
      end

      it "returns true for exact action:resource match" do
        expect(context.can_access?("read", "files")).to be true
        expect(context.can_access?("write", "configs")).to be true
      end

      it "returns false for non-matching permissions" do
        expect(context.can_access?("read", "configs")).to be false
        expect(context.can_access?("write", "files")).to be false
        expect(context.can_access?("delete", "files")).to be false
      end
    end

    context "with wildcard permissions" do
      before do
        context.add_permission("read:*")      # Can read anything
        context.add_permission("*:configs")   # Can do anything with configs
        context.add_permission("*:*")         # Can do anything
      end

      it "returns true for action wildcard" do
        expect(context.can_access?("read", "files")).to be true
        expect(context.can_access?("read", "databases")).to be true
      end

      it "returns true for resource wildcard" do
        expect(context.can_access?("write", "configs")).to be true
        expect(context.can_access?("delete", "configs")).to be true
      end

      it "returns true for full wildcard" do
        expect(context.can_access?("admin", "secrets")).to be true
        expect(context.can_access?("execute", "commands")).to be true
      end
    end

    context "with mixed permissions" do
      before do
        context.add_permission("read:files")
        context.add_permission("*:logs")
        context.add_permission("admin:*")
      end

      it "matches any applicable permission" do
        expect(context.can_access?("read", "files")).to be true   # Exact match
        expect(context.can_access?("write", "logs")).to be true   # Resource wildcard
        expect(context.can_access?("admin", "users")).to be true  # Action wildcard
      end

      it "returns false when no permissions match" do
        expect(context.can_access?("write", "files")).to be false
        expect(context.can_access?("read", "secrets")).to be false
      end
    end
  end

  describe "#add_permission" do
    let(:context) { described_class.new }

    it "adds string permissions" do
      context.add_permission("read")

      expect(context.permissions).to include("read")
    end

    it "adds symbol permissions as strings" do
      context.add_permission(:write)

      expect(context.permissions).to include("write")
    end

    it "allows duplicate permissions" do
      context.add_permission("read")
      context.add_permission("read")

      expect(context.permissions.count("read")).to eq(1) # Set deduplication
    end
  end

  describe "#add_permissions" do
    let(:context) { described_class.new }

    it "adds multiple permissions at once" do
      context.add_permissions(["read", :write, "admin"])

      expect(context.permissions).to include("read", "write", "admin")
    end
  end

  describe "#remove_permission" do
    let(:context) { described_class.new }

    it "removes existing permissions" do
      context.add_permission("read")
      context.add_permission("write")

      context.remove_permission("read")

      expect(context.permissions).not_to include("read")
      expect(context.permissions).to include("write")
    end

    it "handles removal of non-existent permissions" do
      expect { context.remove_permission("nonexistent") }.not_to raise_error
    end
  end

  describe "#clear_permissions" do
    let(:context) { described_class.new }

    it "removes all permissions" do
      context.add_permissions(%w[read write admin])
      expect(context.permissions).not_to be_empty

      context.clear_permissions

      expect(context.permissions).to be_empty
    end
  end

  describe "#user_identifier" do
    context "with unauthenticated user" do
      let(:context) { described_class.new(authenticated: false) }

      it "returns 'anonymous'" do
        expect(context.user_identifier).to eq("anonymous")
      end
    end

    context "with authenticated hash user" do
      it "prefers user_id" do
        user = { user_id: "123", sub: "456", email: "test@example.com" }
        context = described_class.new(user: user, authenticated: true)

        expect(context.user_identifier).to eq("123")
      end

      it "falls back to sub" do
        user = { sub: "456", email: "test@example.com" }
        context = described_class.new(user: user, authenticated: true)

        expect(context.user_identifier).to eq("456")
      end

      it "falls back to email" do
        user = { email: "test@example.com" }
        context = described_class.new(user: user, authenticated: true)

        expect(context.user_identifier).to eq("test@example.com")
      end

      it "falls back to api_key" do
        user = { api_key: "secret-key" }
        context = described_class.new(user: user, authenticated: true)

        expect(context.user_identifier).to eq("secret-key")
      end

      it "uses default when no identifiers" do
        user = { role: "admin" }
        context = described_class.new(user: user, authenticated: true)

        expect(context.user_identifier).to eq("authenticated_user")
      end
    end

    context "with string user" do
      it "returns the string" do
        context = described_class.new(user: "user123", authenticated: true)

        expect(context.user_identifier).to eq("user123")
      end
    end

    context "with object user" do
      it "uses id method if available" do
        user_obj = double("user", id: 789)
        context = described_class.new(user: user_obj, authenticated: true)

        expect(context.user_identifier).to eq("789")
      end

      it "uses default when no id method" do
        user_obj = double("user")
        context = described_class.new(user: user_obj, authenticated: true)

        expect(context.user_identifier).to eq("authenticated_user")
      end
    end
  end

  describe "#auth_method" do
    it "returns 'none' when no strategy" do
      context = described_class.new

      expect(context.auth_method).to eq("none")
    end

    it "returns the authentication strategy" do
      context = described_class.new(auth_strategy: "jwt")

      expect(context.auth_method).to eq("jwt")
    end
  end

  describe "#auth_recent?" do
    context "with unauthenticated user" do
      let(:context) { described_class.new(authenticated: false) }

      it "returns false" do
        expect(context.auth_recent?).to be false
      end
    end

    context "with authenticated user" do
      it "returns true for recent authentication" do
        recent_time = Time.now - 30 # 30 seconds ago
        context = described_class.new(authenticated: true, authenticated_at: recent_time)

        expect(context.auth_recent?).to be true
      end

      it "returns false for old authentication" do
        old_time = Time.now - 7200 # 2 hours ago
        context = described_class.new(authenticated: true, authenticated_at: old_time)

        expect(context.auth_recent?).to be false
      end

      it "respects custom max_age" do
        time_90_mins_ago = Time.now - 5400 # 90 minutes ago
        context = described_class.new(authenticated: true, authenticated_at: time_90_mins_ago)

        expect(context.auth_recent?(max_age: 3600)).to be false   # 1 hour limit
        expect(context.auth_recent?(max_age: 7200)).to be true    # 2 hour limit
      end
    end
  end

  describe "#to_h" do
    let(:auth_time) { Time.parse("2023-01-01 12:00:00 UTC") }
    let(:context) do
      described_class.new(
        user: { user_id: "123" },
        authenticated: true,
        auth_strategy: "api_key",
        authenticated_at: auth_time
      )
    end

    before do
      context.add_permissions(%w[read write])
    end

    it "returns hash representation" do
      result = context.to_h

      expect(result[:authenticated]).to be true
      expect(result[:user_identifier]).to eq("123")
      expect(result[:auth_strategy]).to eq("api_key")
      expect(result[:authenticated_at]).to eq("2023-01-01T12:00:00Z")
      expect(result[:permissions]).to contain_exactly("read", "write")
    end
  end

  describe ".anonymous" do
    it "creates unauthenticated session context" do
      context = described_class.anonymous

      expect(context.authenticated?).to be false
      expect(context.user).to be_nil
      expect(context.permissions).to be_empty
    end
  end

  describe ".from_auth_result" do
    context "with successful authentication" do
      let(:auth_result) do
        {
          authenticated: true,
          user: {
            user_id: "123",
            strategy: "api_key",
            authenticated_at: auth_time
          }
        }
      end

      it "creates authenticated session context" do
        context = described_class.from_auth_result(auth_result)

        expect(context.authenticated?).to be true
        expect(context.user).to eq(auth_result[:user])
        expect(context.auth_strategy).to eq("api_key")
        expect(context.authenticated_at).to eq(auth_time)
      end
    end

    context "with failed authentication" do
      let(:auth_result) { { authenticated: false } }

      it "creates anonymous session context" do
        context = described_class.from_auth_result(auth_result)

        expect(context.authenticated?).to be false
        expect(context.user).to be_nil
      end
    end

    context "with nil auth result" do
      it "creates anonymous session context" do
        context = described_class.from_auth_result(nil)

        expect(context.authenticated?).to be false
      end
    end
  end
end
