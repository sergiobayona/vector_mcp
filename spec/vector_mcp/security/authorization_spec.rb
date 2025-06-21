# frozen_string_literal: true

require "spec_helper"

RSpec.describe VectorMCP::Security::Authorization do
  let(:authorization) { described_class.new }

  describe "#initialize" do
    it "starts disabled with no policies" do
      expect(authorization.enabled).to be false
      expect(authorization.policies).to be_empty
    end
  end

  describe "#enable!" do
    it "enables authorization" do
      authorization.enable!

      expect(authorization.enabled).to be true
    end
  end

  describe "#disable!" do
    it "disables authorization" do
      authorization.enable!
      authorization.disable!

      expect(authorization.enabled).to be false
    end
  end

  describe "#add_policy" do
    let(:policy) { proc { |_user, _action, _resource| true } }

    it "adds a policy for a resource type" do
      authorization.add_policy(:tool, &policy)

      expect(authorization.policies[:tool]).to eq(policy)
    end

    it "supports multiple resource types" do
      tool_policy = proc { |_user, _action, _resource| true }
      resource_policy = proc { |_user, _action, _resource| false }

      authorization.add_policy(:tool, &tool_policy)
      authorization.add_policy(:resource, &resource_policy)

      expect(authorization.policies[:tool]).to eq(tool_policy)
      expect(authorization.policies[:resource]).to eq(resource_policy)
    end
  end

  describe "#remove_policy" do
    it "removes a policy for a resource type" do
      policy = proc { |_user, _action, _resource| true }
      authorization.add_policy(:tool, &policy)

      authorization.remove_policy(:tool)

      expect(authorization.policies).not_to have_key(:tool)
    end
  end

  describe "#authorize" do
    let(:user) { { user_id: 123, role: "admin" } }
    let(:tool) { VectorMCP::Definitions::Tool.new(name: "test_tool", description: "Test", input_schema: {}, handler: proc {}) }
    let(:resource) { VectorMCP::Definitions::Resource.new(uri: "test://resource", name: "Test Resource", description: "Test", mime_type: "text/plain", handler: proc {}) }

    context "when disabled" do
      it "returns true (allows all access)" do
        result = authorization.authorize(user, :call, tool)

        expect(result).to be true
      end
    end

    context "when enabled" do
      before { authorization.enable! }

      context "with no policy defined" do
        it "returns true (opt-in authorization)" do
          result = authorization.authorize(user, :call, tool)

          expect(result).to be true
        end
      end

      context "with policy defined" do
        context "that returns truthy value" do
          before do
            authorization.add_policy(:tool) { |user, _action, _resource| user[:role] == "admin" }
          end

          it "returns true when policy allows access" do
            result = authorization.authorize(user, :call, tool)

            expect(result).to be true
          end

          it "returns false when policy denies access" do
            user[:role] = "user"
            result = authorization.authorize(user, :call, tool)

            expect(result).to be false
          end
        end

        context "that returns falsy value" do
          before do
            authorization.add_policy(:tool) { |_user, _action, _resource| false }
          end

          it "returns false" do
            result = authorization.authorize(user, :call, tool)

            expect(result).to be false
          end
        end

        context "that returns nil" do
          before do
            authorization.add_policy(:tool) { |_user, _action, _resource| nil }
          end

          it "returns false" do
            result = authorization.authorize(user, :call, tool)

            expect(result).to be false
          end
        end

        context "that raises an error" do
          before do
            authorization.add_policy(:tool) { |_user, _action, _resource| raise StandardError, "Policy error" }
          end

          it "returns false for safety" do
            result = authorization.authorize(user, :call, tool)

            expect(result).to be false
          end
        end
      end

      context "with different resource types" do
        before do
          authorization.add_policy(:tool) { |user, _action, _resource| user[:role] == "admin" }
          authorization.add_policy(:resource) { |user, _action, _resource| user[:role] == "user" }
        end

        it "applies correct policy based on resource type" do
          admin_user = { role: "admin" }
          regular_user = { role: "user" }

          expect(authorization.authorize(admin_user, :call, tool)).to be true
          expect(authorization.authorize(regular_user, :call, tool)).to be false

          expect(authorization.authorize(admin_user, :read, resource)).to be false
          expect(authorization.authorize(regular_user, :read, resource)).to be true
        end
      end
    end
  end

  describe "#required?" do
    it "returns false when disabled" do
      expect(authorization.required?).to be false
    end

    it "returns true when enabled" do
      authorization.enable!

      expect(authorization.required?).to be true
    end
  end

  describe "#policy_types" do
    it "returns empty array when no policies" do
      expect(authorization.policy_types).to eq([])
    end

    it "returns array of policy types" do
      authorization.add_policy(:tool) { true }
      authorization.add_policy(:resource) { false }

      expect(authorization.policy_types).to contain_exactly(:tool, :resource)
    end
  end

  describe "resource type determination" do
    let(:tool) { VectorMCP::Definitions::Tool.new(name: "test_tool", description: "Test", input_schema: {}, handler: proc {}) }
    let(:resource) { VectorMCP::Definitions::Resource.new(uri: "test://resource", name: "Test Resource", description: "Test", mime_type: "text/plain", handler: proc {}) }
    let(:prompt) { VectorMCP::Definitions::Prompt.new(name: "test_prompt", description: "Test", handler: proc {}) }
    let(:root) { VectorMCP::Definitions::Root.new(uri: "file:///test", name: "Test Root") }
    let(:unknown_resource) { double("UnknownResource") }

    before { authorization.enable! }

    it "correctly identifies tool resources" do
      authorization.add_policy(:tool) { |_user, _action, _resource| :tool_policy_called }

      result = authorization.authorize({}, :call, tool)

      expect(result).to be_truthy # :tool_policy_called is truthy
    end

    it "correctly identifies resource resources" do
      authorization.add_policy(:resource) { |_user, _action, _resource| :resource_policy_called }

      result = authorization.authorize({}, :read, resource)

      expect(result).to be_truthy # :resource_policy_called is truthy
    end

    it "correctly identifies prompt resources" do
      authorization.add_policy(:prompt) { |_user, _action, _resource| :prompt_policy_called }

      result = authorization.authorize({}, :get, prompt)

      expect(result).to be_truthy # :prompt_policy_called is truthy
    end

    it "correctly identifies root resources" do
      authorization.add_policy(:root) { |_user, _action, _resource| :root_policy_called }

      result = authorization.authorize({}, :list, root)

      expect(result).to be_truthy # :root_policy_called is truthy
    end

    it "handles unknown resource types" do
      # No policy for :unknown type, should return true (opt-in)
      result = authorization.authorize({}, :action, unknown_resource)

      expect(result).to be true
    end

    it "infers resource type from class name for unknown types" do
      custom_class = Class.new do
        def self.name
          "VectorMCP::Custom::MyResource"
        end
      end
      custom_resource = custom_class.new

      authorization.add_policy(:myresource) { |_user, _action, _resource| :custom_policy_called }

      result = authorization.authorize({}, :action, custom_resource)

      expect(result).to be_truthy # :custom_policy_called is truthy
    end
  end

  describe "policy execution context" do
    let(:user) { { user_id: 123, permissions: %w[read write] } }
    let(:tool) { VectorMCP::Definitions::Tool.new(name: "test_tool", description: "Test", input_schema: {}, handler: proc {}) }

    before { authorization.enable! }

    it "passes correct parameters to policy" do
      received_params = nil
      authorization.add_policy(:tool) do |u, a, r|
        received_params = [u, a, r]
        true
      end

      authorization.authorize(user, :call, tool)

      expect(received_params).to eq([user, :call, tool])
    end

    it "allows policies to access user properties" do
      authorization.add_policy(:tool) do |user, action, _resource|
        user[:permissions].include?("write") && action == :call
      end

      result = authorization.authorize(user, :call, tool)

      expect(result).to be true
    end

    it "allows policies to access resource properties" do
      authorization.add_policy(:tool) do |_user, _action, resource|
        resource.name.start_with?("test_")
      end

      result = authorization.authorize(user, :call, tool)

      expect(result).to be true
    end
  end
end
