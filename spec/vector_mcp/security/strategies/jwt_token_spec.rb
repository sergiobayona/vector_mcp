# frozen_string_literal: true

require "spec_helper"

RSpec.describe VectorMCP::Security::Strategies::JwtToken do
  let(:secret) { "test-secret-key" }
  let(:strategy) { described_class.new(secret: secret) }

  # Mock JWT module when not available
  before do
    unless defined?(JWT)
      stub_const("JWT", Module.new)
      JWT.singleton_class.class_eval do
        def decode(token, _secret, _verify, _options = {})
          case token
          when "valid.jwt.token"
            [{ "user_id" => 123, "email" => "test@example.com" }, { "alg" => "HS256" }]
          when "expired.jwt.token"
            raise JWT::ExpiredSignature, "Token has expired"
          when "invalid.signature.token"
            raise JWT::VerificationError, "Invalid signature"
          when "invalid.issuer.token"
            raise JWT::InvalidIssuerError, "Invalid issuer"
          when "invalid.audience.token"
            raise JWT::InvalidAudienceError, "Invalid audience"
          when "malformed.token"
            raise JWT::DecodeError, "Invalid token format"
          else
            raise StandardError, "Unexpected error"
          end
        end

        def encode(_payload, _secret, _algorithm = "HS256")
          "encoded.jwt.token"
        end
      end

      # Define JWT exception classes
      JWT.const_set("ExpiredSignature", Class.new(StandardError))
      JWT.const_set("VerificationError", Class.new(StandardError))
      JWT.const_set("InvalidIssuerError", Class.new(StandardError))
      JWT.const_set("InvalidAudienceError", Class.new(StandardError))
      JWT.const_set("DecodeError", Class.new(StandardError))
    end
  end

  describe "#initialize" do
    it "initializes with secret and default options" do
      strategy = described_class.new(secret: "test-secret")

      expect(strategy.secret).to eq("test-secret")
      expect(strategy.algorithm).to eq("HS256")
      expect(strategy.options).to include(algorithm: "HS256", verify_expiration: true)
    end

    it "accepts custom algorithm" do
      strategy = described_class.new(secret: "test-secret", algorithm: "HS512")

      expect(strategy.algorithm).to eq("HS512")
      expect(strategy.options[:algorithm]).to eq("HS512")
    end

    it "accepts custom options" do
      custom_options = { verify_expiration: false, verify_iss: true, iss: "test-issuer" }
      strategy = described_class.new(secret: "test-secret", **custom_options)

      expect(strategy.options).to include(custom_options)
      expect(strategy.options[:algorithm]).to eq("HS256") # Default preserved
    end

    it "raises error when JWT gem is not available and we don't mock it" do
      hide_const("JWT")

      expect do
        described_class.new(secret: "test-secret")
      end.to raise_error(LoadError, "JWT gem is required for JWT authentication strategy")
    end
  end

  describe "#authenticate" do
    let(:base_request) { { headers: {}, params: {} } }

    context "with valid JWT token" do
      let(:request) { base_request.merge(headers: { "Authorization" => "Bearer valid.jwt.token" }) }

      it "returns user information on successful authentication" do
        result = strategy.authenticate(request)

        expect(result).to be_a(Hash)
        expect(result["user_id"]).to eq(123)
        expect(result["email"]).to eq("test@example.com")
        expect(result[:strategy]).to eq("jwt")
        expect(result[:authenticated_at]).to be_a(Time)
        expect(result[:jwt_headers]).to eq({ "alg" => "HS256" })
      end
    end

    context "with expired token" do
      let(:request) { base_request.merge(headers: { "Authorization" => "Bearer expired.jwt.token" }) }

      it "returns false" do
        result = strategy.authenticate(request)

        expect(result).to be false
      end
    end

    context "with invalid signature" do
      let(:request) { base_request.merge(headers: { "Authorization" => "Bearer invalid.signature.token" }) }

      it "returns false" do
        result = strategy.authenticate(request)

        expect(result).to be false
      end
    end

    context "with invalid issuer" do
      let(:request) { base_request.merge(headers: { "Authorization" => "Bearer invalid.issuer.token" }) }

      it "returns false" do
        result = strategy.authenticate(request)

        expect(result).to be false
      end
    end

    context "with invalid audience" do
      let(:request) { base_request.merge(headers: { "Authorization" => "Bearer invalid.audience.token" }) }

      it "returns false" do
        result = strategy.authenticate(request)

        expect(result).to be false
      end
    end

    context "with malformed token" do
      let(:request) { base_request.merge(headers: { "Authorization" => "Bearer malformed.token" }) }

      it "returns false" do
        result = strategy.authenticate(request)

        expect(result).to be false
      end
    end

    context "with unexpected error" do
      let(:request) { base_request.merge(headers: { "Authorization" => "Bearer unexpected.error.token" }) }

      it "returns false" do
        result = strategy.authenticate(request)

        expect(result).to be false
      end
    end

    context "with no token provided" do
      let(:request) { base_request }

      it "returns false" do
        result = strategy.authenticate(request)

        expect(result).to be false
      end
    end

    context "with empty token" do
      let(:request) { base_request.merge(headers: { "Authorization" => "Bearer " }) }

      it "returns false" do
        result = strategy.authenticate(request)

        expect(result).to be false
      end
    end
  end

  describe "#generate_token" do
    let(:payload) { { user_id: 123, email: "test@example.com" } }

    it "generates a JWT token with default expiration" do
      token = strategy.generate_token(payload)

      expect(token).to eq("encoded.jwt.token")
    end

    it "generates a JWT token with custom expiration" do
      token = strategy.generate_token(payload, expires_in: 7200)

      expect(token).to eq("encoded.jwt.token")
    end

    it "adds expiration claim to payload" do
      allow(JWT).to receive(:encode).and_call_original

      strategy.generate_token(payload, expires_in: 3600)

      expect(JWT).to have_received(:encode) do |actual_payload, _, _|
        expect(actual_payload).to include(:exp)
        expect(actual_payload[:exp]).to be > Time.now.to_i
        expect(actual_payload[:exp]).to be <= (Time.now + 3600).to_i
      end
    end
  end

  describe ".available?" do
    it "returns truthy when JWT gem is available" do
      expect(described_class.available?).to be_truthy
    end
  end

  describe "secret validation" do
    context "with nil secret" do
      it "initializes but may fail authentication" do
        strategy = described_class.new(secret: nil)
        expect(strategy.secret).to be_nil
      end
    end

    context "with empty secret" do
      it "initializes but may fail authentication" do
        strategy = described_class.new(secret: "")
        expect(strategy.secret).to eq("")
      end
    end
  end

  describe "token extraction" do
    context "from Authorization header" do
      it "extracts bearer token" do
        request = { headers: { "Authorization" => "Bearer test.jwt.token" } }
        token = strategy.send(:extract_token, request)

        expect(token).to eq("test.jwt.token")
      end

      it "handles case-insensitive headers" do
        request = { headers: { "authorization" => "Bearer test.jwt.token" } }
        token = strategy.send(:extract_token, request)

        expect(token).to eq("test.jwt.token")
      end

      it "returns nil for non-bearer authorization" do
        request = { headers: { "Authorization" => "Basic dGVzdDp0ZXN0" } }
        token = strategy.send(:extract_token, request)

        expect(token).to be_nil
      end
    end

    context "from custom JWT header" do
      it "extracts from X-JWT-Token header" do
        request = { headers: { "X-JWT-Token" => "custom.jwt.token" } }
        token = strategy.send(:extract_token, request)

        expect(token).to eq("custom.jwt.token")
      end

      it "handles case-insensitive custom header" do
        request = { headers: { "x-jwt-token" => "custom.jwt.token" } }
        token = strategy.send(:extract_token, request)

        expect(token).to eq("custom.jwt.token")
      end
    end

    context "from query parameters" do
      it "extracts from jwt_token parameter" do
        request = { params: { "jwt_token" => "query.jwt.token" } }
        token = strategy.send(:extract_token, request)

        expect(token).to eq("query.jwt.token")
      end

      it "extracts from token parameter" do
        request = { params: { "token" => "query.jwt.token" } }
        token = strategy.send(:extract_token, request)

        expect(token).to eq("query.jwt.token")
      end

      it "prefers jwt_token over token parameter" do
        request = { params: { "jwt_token" => "preferred.token", "token" => "fallback.token" } }
        token = strategy.send(:extract_token, request)

        expect(token).to eq("preferred.token")
      end
    end

    context "with multiple token sources" do
      it "prefers Authorization header over custom header" do
        request = {
          headers: {
            "Authorization" => "Bearer auth.token",
            "X-JWT-Token" => "custom.token"
          }
        }
        token = strategy.send(:extract_token, request)

        expect(token).to eq("auth.token")
      end

      it "prefers custom header over query parameters" do
        request = {
          headers: { "X-JWT-Token" => "custom.token" },
          params: { "jwt_token" => "query.token" }
        }
        token = strategy.send(:extract_token, request)

        expect(token).to eq("custom.token")
      end
    end

    context "with no token found" do
      it "returns nil when no token sources are present" do
        request = { headers: {}, params: {} }
        token = strategy.send(:extract_token, request)

        expect(token).to be_nil
      end

      it "returns nil when headers and params are missing" do
        request = {}
        token = strategy.send(:extract_token, request)

        expect(token).to be_nil
      end
    end
  end

  describe "algorithm validation" do
    it "accepts valid HMAC algorithms" do
      %w[HS256 HS384 HS512].each do |algorithm|
        strategy = described_class.new(secret: "test", algorithm: algorithm)
        expect(strategy.algorithm).to eq(algorithm)
      end
    end

    it "accepts RSA algorithms" do
      %w[RS256 RS384 RS512].each do |algorithm|
        strategy = described_class.new(secret: "test", algorithm: algorithm)
        expect(strategy.algorithm).to eq(algorithm)
      end
    end

    it "accepts ECDSA algorithms" do
      %w[ES256 ES384 ES512].each do |algorithm|
        strategy = described_class.new(secret: "test", algorithm: algorithm)
        expect(strategy.algorithm).to eq(algorithm)
      end
    end
  end

  describe "options validation" do
    it "merges custom options with defaults" do
      custom_options = {
        verify_iss: true,
        iss: "test-issuer",
        verify_aud: true,
        aud: "test-audience"
      }
      strategy = described_class.new(secret: "test", **custom_options)

      expect(strategy.options).to include(custom_options)
      expect(strategy.options[:algorithm]).to eq("HS256")
      expect(strategy.options[:verify_expiration]).to be true
    end

    it "allows overriding default options" do
      strategy = described_class.new(
        secret: "test",
        verify_expiration: false,
        algorithm: "HS512"
      )

      expect(strategy.options[:verify_expiration]).to be false
      expect(strategy.options[:algorithm]).to eq("HS512")
    end
  end

  describe "edge cases" do
    context "with malformed request objects" do
      it "handles request with string keys" do
        request = { "headers" => { "Authorization" => "Bearer valid.jwt.token" } }
        result = strategy.authenticate(request)

        expect(result).to be_a(Hash)
      end

      it "handles missing headers key" do
        request = { params: {} }
        result = strategy.authenticate(request)

        expect(result).to be false
      end

      it "handles missing params key" do
        request = { headers: {} }
        result = strategy.authenticate(request)

        expect(result).to be false
      end
    end

    context "with empty or whitespace tokens" do
      it "handles empty bearer token" do
        request = { headers: { "Authorization" => "Bearer" } }
        result = strategy.authenticate(request)

        expect(result).to be false
      end

      it "handles whitespace-only token" do
        request = { headers: { "Authorization" => "Bearer   " } }
        result = strategy.authenticate(request)

        expect(result).to be false
      end
    end
  end
end
