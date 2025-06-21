# frozen_string_literal: true

require "spec_helper"

RSpec.describe VectorMCP::Security::Middleware do
  let(:auth_manager) { instance_double(VectorMCP::Security::AuthManager) }
  let(:authorization) { instance_double(VectorMCP::Security::Authorization) }
  let(:middleware) { described_class.new(auth_manager, authorization) }
  let(:request) { { headers: { "X-API-Key" => "test-key" }, params: {} } }

  describe "#initialize" do
    it "initializes with auth manager and authorization" do
      expect(middleware.auth_manager).to eq(auth_manager)
      expect(middleware.authorization).to eq(authorization)
    end
  end

  describe "#authenticate_request" do
    let(:auth_result) { { authenticated: true, user: { user_id: 123 } } }

    before do
      allow(auth_manager).to receive(:authenticate).with(request, strategy: nil).and_return(auth_result)
    end

    it "authenticates request and returns session context" do
      result = middleware.authenticate_request(request)

      expect(result).to be_a(VectorMCP::Security::SessionContext)
      expect(auth_manager).to have_received(:authenticate).with(request, strategy: nil)
    end

    it "supports strategy override" do
      allow(auth_manager).to receive(:authenticate).with(request, strategy: :jwt).and_return(auth_result)

      middleware.authenticate_request(request, strategy: :jwt)

      expect(auth_manager).to have_received(:authenticate).with(request, strategy: :jwt)
    end
  end

  describe "#authorize_action" do
    let(:session_context) { instance_double(VectorMCP::Security::SessionContext, user: { user_id: 123 }) }
    let(:resource) { double("resource") }

    before do
      allow(authorization).to receive(:required?).and_return(true)
      allow(authorization).to receive(:authorize).with(session_context.user, :read, resource).and_return(true)
    end

    it "checks authorization policy" do
      result = middleware.authorize_action(session_context, :read, resource)

      expect(result).to be true
      expect(authorization).to have_received(:authorize).with(session_context.user, :read, resource)
    end

    it "returns true when authorization is disabled" do
      allow(authorization).to receive(:required?).and_return(false)

      result = middleware.authorize_action(session_context, :read, resource)

      expect(result).to be true
      expect(authorization).not_to have_received(:authorize)
    end
  end

  describe "#process_request" do
    let(:session_context) { instance_double(VectorMCP::Security::SessionContext, authenticated?: true, user: { user_id: 123 }) }
    let(:resource) { double("resource") }

    before do
      allow(middleware).to receive(:authenticate_request).with(request).and_return(session_context)
      allow(auth_manager).to receive(:required?).and_return(false)
      allow(middleware).to receive(:authorize_action).with(session_context, :access, resource).and_return(true)
    end

    context "when security is disabled" do
      it "returns success" do
        result = middleware.process_request(request)

        expect(result[:success]).to be true
        expect(result[:session_context]).to eq(session_context)
      end
    end

    context "when authentication is required" do
      before do
        allow(auth_manager).to receive(:required?).and_return(true)
      end

      context "and authentication succeeds" do
        it "returns success" do
          result = middleware.process_request(request)

          expect(result[:success]).to be true
          expect(result[:session_context]).to eq(session_context)
        end
      end

      context "and authentication fails" do
        let(:unauthenticated_context) { instance_double(VectorMCP::Security::SessionContext, authenticated?: false) }

        before do
          allow(middleware).to receive(:authenticate_request).with(request).and_return(unauthenticated_context)
        end

        it "returns authentication required error" do
          result = middleware.process_request(request)

          expect(result[:success]).to be false
          expect(result[:error]).to eq("Authentication required")
          expect(result[:error_code]).to eq("AUTHENTICATION_REQUIRED")
          expect(result[:session_context]).to eq(unauthenticated_context)
        end
      end
    end

    context "when authorization fails" do
      before do
        allow(middleware).to receive(:authorize_action).with(session_context, :read, resource).and_return(false)
      end

      it "returns authorization failed error" do
        result = middleware.process_request(request, action: :read, resource: resource)

        expect(result[:success]).to be false
        expect(result[:error]).to eq("Access denied")
        expect(result[:error_code]).to eq("AUTHORIZATION_FAILED")
        expect(result[:session_context]).to eq(session_context)
      end
    end

    context "with custom action and resource" do
      before do
        allow(middleware).to receive(:authorize_action).with(session_context, :write, resource).and_return(true)
      end

      it "uses provided action and resource for authorization" do
        result = middleware.process_request(request, action: :write, resource: resource)

        expect(result[:success]).to be true
        expect(middleware).to have_received(:authorize_action).with(session_context, :write, resource)
      end
    end
  end

  describe "#normalize_request" do
    context "with hash request" do
      it "returns request as-is" do
        hash_request = { headers: {}, params: {} }
        result = middleware.normalize_request(hash_request)

        expect(result).to eq(hash_request)
      end
    end

    context "with rack environment" do
      let(:rack_env) do
        {
          "REQUEST_METHOD" => "POST",
          "PATH_INFO" => "/test",
          "HTTP_X_API_KEY" => "test-key",
          "HTTP_AUTHORIZATION" => "Bearer token",
          "CONTENT_TYPE" => "application/json",
          "QUERY_STRING" => "param1=value1&param2=value2"
        }
      end

      it "extracts request data from rack environment" do
        result = middleware.normalize_request(rack_env)

        expect(result[:headers]["X-API-Key"]).to eq("test-key")
        expect(result[:headers]["Authorization"]).to eq("Bearer token")
        expect(result[:headers]["Content-Type"]).to eq("application/json")
        expect(result[:params]["param1"]).to eq("value1")
        expect(result[:params]["param2"]).to eq("value2")
        expect(result[:method]).to eq("POST")
        expect(result[:path]).to eq("/test")
        expect(result[:rack_env]).to eq(rack_env)
      end
    end

    context "with unknown request type" do
      it "returns default request structure" do
        unknown_request = "unknown"
        result = middleware.normalize_request(unknown_request)

        expect(result).to eq({ headers: {}, params: {} })
      end
    end
  end

  describe "#security_enabled?" do
    it "returns true when authentication is required" do
      allow(auth_manager).to receive(:required?).and_return(true)
      allow(authorization).to receive(:required?).and_return(false)

      expect(middleware.security_enabled?).to be true
    end

    it "returns true when authorization is required" do
      allow(auth_manager).to receive(:required?).and_return(false)
      allow(authorization).to receive(:required?).and_return(true)

      expect(middleware.security_enabled?).to be true
    end

    it "returns false when neither is required" do
      allow(auth_manager).to receive(:required?).and_return(false)
      allow(authorization).to receive(:required?).and_return(false)

      expect(middleware.security_enabled?).to be false
    end
  end

  describe "#security_status" do
    before do
      allow(auth_manager).to receive(:required?).and_return(true)
      allow(auth_manager).to receive(:available_strategies).and_return(%i[api_key jwt])
      allow(auth_manager).to receive(:default_strategy).and_return(:api_key)
      allow(authorization).to receive(:required?).and_return(true)
      allow(authorization).to receive(:policy_types).and_return(%i[tool resource])
    end

    it "returns comprehensive security status" do
      status = middleware.security_status

      expect(status[:authentication][:enabled]).to be true
      expect(status[:authentication][:strategies]).to eq(%i[api_key jwt])
      expect(status[:authentication][:default_strategy]).to eq(:api_key)
      expect(status[:authorization][:enabled]).to be true
      expect(status[:authorization][:policy_types]).to eq(%i[tool resource])
    end
  end

  describe "private methods" do
    describe "#extract_from_rack_env" do
      let(:env) do
        {
          "REQUEST_METHOD" => "GET",
          "PATH_INFO" => "/api/test",
          "HTTP_X_CUSTOM_HEADER" => "custom-value",
          "HTTP_AUTHORIZATION" => "Bearer token123",
          "CONTENT_TYPE" => "application/json",
          "QUERY_STRING" => "key1=value1&key2=value2"
        }
      end

      it "extracts headers correctly" do
        result = middleware.send(:extract_from_rack_env, env)

        expect(result[:headers]["X-Custom-Header"]).to eq("custom-value")
        expect(result[:headers]["Authorization"]).to eq("Bearer token123")
        expect(result[:headers]["Content-Type"]).to eq("application/json")
      end

      it "extracts query parameters" do
        result = middleware.send(:extract_from_rack_env, env)

        expect(result[:params]["key1"]).to eq("value1")
        expect(result[:params]["key2"]).to eq("value2")
      end

      it "extracts method and path" do
        result = middleware.send(:extract_from_rack_env, env)

        expect(result[:method]).to eq("GET")
        expect(result[:path]).to eq("/api/test")
      end

      it "includes original rack environment" do
        result = middleware.send(:extract_from_rack_env, env)

        expect(result[:rack_env]).to eq(env)
      end

      it "handles missing query string" do
        env.delete("QUERY_STRING")
        result = middleware.send(:extract_from_rack_env, env)

        expect(result[:params]).to eq({})
      end

      it "handles empty query string" do
        env["QUERY_STRING"] = ""
        result = middleware.send(:extract_from_rack_env, env)

        expect(result[:params]).to eq({})
      end
    end
  end
end
