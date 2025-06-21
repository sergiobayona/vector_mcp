# frozen_string_literal: true

require "spec_helper"

RSpec.describe VectorMCP::Server, "Security Features" do
  let(:server) { VectorMCP::Server.new(name: "SecurityTestServer", version: "1.0.0") }
  let(:logger_double) { instance_double("Logger", info: nil, debug: nil, warn: nil, error: nil, fatal: nil, level: nil) }

  before do
    allow(logger_double).to receive(:level=)
    allow(VectorMCP).to receive(:logger).and_return(logger_double)
  end

  describe "security component initialization" do
    it "initializes with security components" do
      expect(server.auth_manager).to be_a(VectorMCP::Security::AuthManager)
      expect(server.authorization).to be_a(VectorMCP::Security::Authorization)
      expect(server.security_middleware).to be_a(VectorMCP::Security::Middleware)
    end

    it "starts with security disabled by default" do
      expect(server.auth_manager.enabled).to be false
      expect(server.authorization.enabled).to be false
      expect(server.security_enabled?).to be false
    end
  end

  describe "#enable_authentication!" do
    context "with API key strategy" do
      it "enables authentication with API keys" do
        server.enable_authentication!(strategy: :api_key, keys: %w[test-key-1 test-key-2])

        expect(server.auth_manager.enabled).to be true
        expect(server.auth_manager.default_strategy).to eq(:api_key)
        expect(server.auth_manager.strategies).to have_key(:api_key)
        expect(logger_double).to have_received(:info).with("Authentication enabled with strategy: api_key")
      end

      it "configures API key strategy with provided keys" do
        server.enable_authentication!(strategy: :api_key, keys: ["secret-key"])

        strategy = server.auth_manager.strategies[:api_key]
        expect(strategy).to be_a(VectorMCP::Security::Strategies::ApiKey)
        expect(strategy.valid_keys).to include("secret-key")
      end

      it "defaults to empty keys if none provided" do
        server.enable_authentication!(strategy: :api_key)

        strategy = server.auth_manager.strategies[:api_key]
        expect(strategy.valid_keys).to be_empty
      end
    end

    context "with JWT strategy" do
      before do
        skip "JWT gem not available" unless defined?(JWT)
      end

      it "enables authentication with JWT" do
        server.enable_authentication!(strategy: :jwt, secret: "jwt-secret")

        expect(server.auth_manager.enabled).to be true
        expect(server.auth_manager.default_strategy).to eq(:jwt)
        expect(server.auth_manager.strategies).to have_key(:jwt)
        expect(logger_double).to have_received(:info).with("Authentication enabled with strategy: jwt")
      end

      it "configures JWT strategy with provided options" do
        server.enable_authentication!(strategy: :jwt, secret: "secret", algorithm: "HS512")

        strategy = server.auth_manager.strategies[:jwt]
        expect(strategy).to be_a(VectorMCP::Security::Strategies::JwtToken)
        expect(strategy.secret).to eq("secret")
        expect(strategy.algorithm).to eq("HS512")
      end
    end

    context "with custom strategy" do
      it "enables authentication with custom handler" do
        custom_handler = proc { |_request| { user_id: 123 } }
        server.enable_authentication!(strategy: :custom, handler: custom_handler)

        expect(server.auth_manager.enabled).to be true
        expect(server.auth_manager.default_strategy).to eq(:custom)
        expect(server.auth_manager.strategies).to have_key(:custom)
        expect(logger_double).to have_received(:info).with("Authentication enabled with strategy: custom")
      end

      it "configures custom strategy with provided handler" do
        custom_handler = proc { |_request| { user_id: 456 } }
        server.enable_authentication!(strategy: :custom, handler: custom_handler)

        strategy = server.auth_manager.strategies[:custom]
        expect(strategy).to be_a(VectorMCP::Security::Strategies::Custom)
        expect(strategy.handler).to eq(custom_handler)
      end
    end

    context "with unknown strategy" do
      it "raises ArgumentError for unknown strategy" do
        expect do
          server.enable_authentication!(strategy: :unknown)
        end.to raise_error(ArgumentError, "Unknown authentication strategy: unknown")
      end
    end

    it "defaults to api_key strategy" do
      server.enable_authentication!

      expect(server.auth_manager.default_strategy).to eq(:api_key)
      expect(server.auth_manager.strategies).to have_key(:api_key)
    end
  end

  describe "#disable_authentication!" do
    it "disables authentication" do
      server.enable_authentication!(strategy: :api_key, keys: ["test-key"])
      expect(server.auth_manager.enabled).to be true

      server.disable_authentication!

      expect(server.auth_manager.enabled).to be false
      expect(server.auth_manager.default_strategy).to be_nil
      expect(logger_double).to have_received(:info).with("Authentication disabled")
    end
  end

  describe "#enable_authorization!" do
    it "enables authorization" do
      server.enable_authorization!

      expect(server.authorization.enabled).to be true
      expect(logger_double).to have_received(:info).with("Authorization enabled")
    end

    it "executes provided configuration block" do
      block_executed = false
      server.enable_authorization! do
        block_executed = true
      end

      expect(block_executed).to be true
      expect(server.authorization.enabled).to be true
    end

    it "provides access to authorization policy methods in block" do
      server.enable_authorization! do
        authorize_tools { |_user, _action, _tool| true }
        authorize_resources { |_user, _action, _resource| false }
      end

      expect(server.authorization.policies).to have_key(:tool)
      expect(server.authorization.policies).to have_key(:resource)
    end
  end

  describe "#disable_authorization!" do
    it "disables authorization" do
      server.enable_authorization!
      expect(server.authorization.enabled).to be true

      server.disable_authorization!

      expect(server.authorization.enabled).to be false
      expect(logger_double).to have_received(:info).with("Authorization disabled")
    end
  end

  describe "authorization policy methods" do
    let(:tool_policy) { proc { |user, _action, _tool| user.present? } }
    let(:resource_policy) { proc { |_user, _action, _resource| true } }
    let(:prompt_policy) { proc { |_user, _action, _prompt| false } }
    let(:root_policy) { proc { |user, _action, _root| user&.dig(:admin) } }

    describe "#authorize_tools" do
      it "adds tool authorization policy" do
        server.authorize_tools(&tool_policy)

        expect(server.authorization.policies[:tool]).to eq(tool_policy)
      end
    end

    describe "#authorize_resources" do
      it "adds resource authorization policy" do
        server.authorize_resources(&resource_policy)

        expect(server.authorization.policies[:resource]).to eq(resource_policy)
      end
    end

    describe "#authorize_prompts" do
      it "adds prompt authorization policy" do
        server.authorize_prompts(&prompt_policy)

        expect(server.authorization.policies[:prompt]).to eq(prompt_policy)
      end
    end

    describe "#authorize_roots" do
      it "adds root authorization policy" do
        server.authorize_roots(&root_policy)

        expect(server.authorization.policies[:root]).to eq(root_policy)
      end
    end
  end

  describe "#security_enabled?" do
    it "returns false when no security is enabled" do
      expect(server.security_enabled?).to be false
    end

    it "returns true when authentication is enabled" do
      server.enable_authentication!(strategy: :api_key, keys: ["test-key"])

      expect(server.security_enabled?).to be true
    end

    it "returns true when authorization is enabled" do
      server.enable_authorization!

      expect(server.security_enabled?).to be true
    end

    it "returns true when both authentication and authorization are enabled" do
      server.enable_authentication!(strategy: :api_key, keys: ["test-key"])
      server.enable_authorization!

      expect(server.security_enabled?).to be true
    end
  end

  describe "#security_status" do
    context "with no security enabled" do
      it "returns disabled status" do
        status = server.security_status

        expect(status[:authentication][:enabled]).to be false
        expect(status[:authorization][:enabled]).to be false
        expect(status[:authentication][:strategies]).to be_empty
        expect(status[:authentication][:default_strategy]).to be_nil
        expect(status[:authorization][:policy_types]).to be_empty
      end
    end

    context "with authentication enabled" do
      before do
        server.enable_authentication!(strategy: :api_key, keys: ["test-key"])
      end

      it "returns authentication status" do
        status = server.security_status

        expect(status[:authentication][:enabled]).to be true
        expect(status[:authentication][:strategies]).to include(:api_key)
        expect(status[:authentication][:default_strategy]).to eq(:api_key)
        expect(status[:authorization][:enabled]).to be false
      end
    end

    context "with authorization enabled" do
      before do
        server.enable_authorization! do
          authorize_tools { |_user, _action, _tool| true }
          authorize_resources { |_user, _action, _resource| true }
        end
      end

      it "returns authorization status" do
        status = server.security_status

        expect(status[:authentication][:enabled]).to be false
        expect(status[:authorization][:enabled]).to be true
        expect(status[:authorization][:policy_types]).to include(:tool, :resource)
      end
    end

    context "with both authentication and authorization enabled" do
      before do
        skip "JWT gem not available" unless defined?(JWT)
        server.enable_authentication!(strategy: :jwt, secret: "secret")
        server.enable_authorization! do
          authorize_tools { |_user, _action, _tool| true }
        end
      end

      it "returns complete security status" do
        status = server.security_status

        expect(status[:authentication][:enabled]).to be true
        expect(status[:authentication][:strategies]).to include(:jwt)
        expect(status[:authentication][:default_strategy]).to eq(:jwt)
        expect(status[:authorization][:enabled]).to be true
        expect(status[:authorization][:policy_types]).to include(:tool)
      end
    end
  end

  describe "private authentication strategy methods" do
    describe "#add_api_key_auth" do
      it "creates and adds API key strategy" do
        server.send(:add_api_key_auth, %w[key1 key2])

        strategy = server.auth_manager.strategies[:api_key]
        expect(strategy).to be_a(VectorMCP::Security::Strategies::ApiKey)
        expect(strategy.valid_keys).to include("key1", "key2")
      end
    end

    describe "#add_jwt_auth" do
      before do
        skip "JWT gem not available" unless defined?(JWT)
      end

      it "creates and adds JWT strategy with options" do
        options = { secret: "secret", algorithm: "HS256" }
        server.send(:add_jwt_auth, options)

        strategy = server.auth_manager.strategies[:jwt]
        expect(strategy).to be_a(VectorMCP::Security::Strategies::JwtToken)
        expect(strategy.secret).to eq("secret")
        expect(strategy.algorithm).to eq("HS256")
      end
    end

    describe "#add_custom_auth" do
      it "creates and adds custom strategy with handler" do
        handler = proc { |_request| { user_id: 123 } }
        server.send(:add_custom_auth, &handler)

        strategy = server.auth_manager.strategies[:custom]
        expect(strategy).to be_a(VectorMCP::Security::Strategies::Custom)
        expect(strategy.handler).to eq(handler)
      end
    end
  end

  describe "integration with existing functionality" do
    it "does not interfere with tool registration when security is disabled" do
      expect do
        server.register_tool(name: "test_tool", description: "Test", input_schema: {}) { |_args| "result" }
      end.not_to raise_error

      expect(server.tools).to have_key("test_tool")
    end

    it "does not interfere with tool registration when security is enabled" do
      server.enable_authentication!(strategy: :api_key, keys: ["test-key"])
      server.enable_authorization!

      expect do
        server.register_tool(name: "test_tool", description: "Test", input_schema: {}) { |_args| "result" }
      end.not_to raise_error

      expect(server.tools).to have_key("test_tool")
    end

    it "maintains backward compatibility with existing server initialization" do
      # Test that servers can still be created and used without any security configuration
      basic_server = VectorMCP::Server.new(name: "BasicServer", version: "1.0.0")

      expect(basic_server.security_enabled?).to be false
      expect do
        basic_server.register_tool(name: "basic_tool", description: "Basic", input_schema: {}) { "ok" }
      end.not_to raise_error
    end
  end
end
