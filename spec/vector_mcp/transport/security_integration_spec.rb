# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Transport Security Integration" do
  let(:server) { VectorMCP::Server.new(name: "SecurityTestServer", version: "1.0.0") }
  let(:logger_double) { instance_double("Logger", info: nil, debug: nil, warn: nil, error: nil, fatal: nil, level: nil) }

  before do
    allow(logger_double).to receive(:level=)
    allow(VectorMCP).to receive(:logger).and_return(logger_double)

    # Register a test tool
    server.register_tool(
      name: "secure_tool",
      description: "A tool that requires authentication",
      input_schema: { type: "object", properties: { message: { type: "string" } } }
    ) do |args, session_context|
      user_id = session_context&.user_identifier || "anonymous"
      "Secure response for #{user_id}: #{args["message"]}"
    end
  end

  describe "SSE Transport Security" do
    let(:transport) { VectorMCP::Transport::Sse.new(server) }

    before do
      server.enable_authentication!(strategy: :api_key, keys: ["valid-api-key", "admin-key"])
      server.enable_authorization! do
        authorize_tools do |user, action, tool|
          case tool.name
          when "secure_tool"
            user && (user[:api_key] == "valid-api-key" || user[:api_key] == "admin-key")
          else
            true
          end
        end
      end
    end

    describe "request authentication" do
      context "with valid API key in header" do
        let(:rack_env) do
          {
            "REQUEST_METHOD" => "POST",
            "PATH_INFO" => "/message",
            "HTTP_X_API_KEY" => "valid-api-key",
            "CONTENT_TYPE" => "application/json",
            "QUERY_STRING" => "session_id=test-session"
          }
        end

        it "successfully authenticates request" do
          result = server.security_middleware.process_request(rack_env)

          expect(result[:success]).to be true
          expect(result[:session_context].authenticated?).to be true
          expect(result[:session_context].user[:api_key]).to eq("valid-api-key")
        end
      end

      context "with valid API key in Authorization header" do
        let(:rack_env) do
          {
            "REQUEST_METHOD" => "POST",
            "PATH_INFO" => "/message",
            "HTTP_AUTHORIZATION" => "Bearer valid-api-key",
            "CONTENT_TYPE" => "application/json",
            "QUERY_STRING" => "session_id=test-session"
          }
        end

        it "successfully authenticates request" do
          result = server.security_middleware.process_request(rack_env)

          expect(result[:success]).to be true
          expect(result[:session_context].authenticated?).to be true
          expect(result[:session_context].user[:api_key]).to eq("valid-api-key")
        end
      end

      context "with invalid API key" do
        let(:rack_env) do
          {
            "REQUEST_METHOD" => "POST",
            "PATH_INFO" => "/message",
            "HTTP_X_API_KEY" => "invalid-key",
            "CONTENT_TYPE" => "application/json",
            "QUERY_STRING" => "session_id=test-session"
          }
        end

        it "rejects authentication" do
          result = server.security_middleware.process_request(rack_env)

          expect(result[:success]).to be false
          expect(result[:error]).to eq("Authentication required")
          expect(result[:error_code]).to eq("AUTHENTICATION_REQUIRED")
        end
      end

      context "with no authentication provided" do
        let(:rack_env) do
          {
            "REQUEST_METHOD" => "POST",
            "PATH_INFO" => "/message",
            "CONTENT_TYPE" => "application/json",
            "QUERY_STRING" => "session_id=test-session"
          }
        end

        it "rejects request" do
          result = server.security_middleware.process_request(rack_env)

          expect(result[:success]).to be false
          expect(result[:error]).to eq("Authentication required")
        end
      end
    end

    describe "query parameter authentication" do
      context "with API key in query string" do
        let(:rack_env) do
          {
            "REQUEST_METHOD" => "POST",
            "PATH_INFO" => "/message",
            "CONTENT_TYPE" => "application/json",
            "QUERY_STRING" => "session_id=test-session&api_key=valid-api-key"
          }
        end

        it "successfully authenticates request" do
          result = server.security_middleware.process_request(rack_env)

          expect(result[:success]).to be true
          expect(result[:session_context].authenticated?).to be true
          expect(result[:session_context].user[:api_key]).to eq("valid-api-key")
        end
      end

      context "with alternative query parameter name" do
        let(:rack_env) do
          {
            "REQUEST_METHOD" => "POST",
            "PATH_INFO" => "/message",
            "CONTENT_TYPE" => "application/json",
            "QUERY_STRING" => "session_id=test-session&apikey=valid-api-key"
          }
        end

        it "successfully authenticates request" do
          result = server.security_middleware.process_request(rack_env)

          expect(result[:success]).to be true
          expect(result[:session_context].authenticated?).to be true
        end
      end
    end

    describe "authorization for tool access" do
      let(:rack_env) do
        {
          "REQUEST_METHOD" => "POST",
          "PATH_INFO" => "/message",
          "HTTP_X_API_KEY" => "valid-api-key",
          "CONTENT_TYPE" => "application/json",
          "QUERY_STRING" => "session_id=test-session"
        }
      end

      let(:tool) { server.tools["secure_tool"] }

      it "allows access to authorized tools" do
        security_result = server.security_middleware.process_request(rack_env)
        session_context = security_result[:session_context]

        authorization_result = server.security_middleware.authorize_action(
          session_context, :call, tool
        )

        expect(authorization_result).to be true
      end

      context "with unauthorized API key" do
        before do
          server.enable_authentication!(strategy: :api_key, keys: ["unauthorized-key"])
        end

        let(:rack_env_unauthorized) do
          rack_env.merge("HTTP_X_API_KEY" => "unauthorized-key")
        end

        it "denies access to secure tools" do
          security_result = server.security_middleware.process_request(rack_env_unauthorized)
          session_context = security_result[:session_context]

          authorization_result = server.security_middleware.authorize_action(
            session_context, :call, tool
          )

          expect(authorization_result).to be false
        end
      end
    end
  end

  describe "Stdio Transport Security" do
    let(:transport) { VectorMCP::Transport::Stdio.new(server) }
    let(:session) { VectorMCP::Session.new(server) }

    before do
      server.enable_authentication!(strategy: :custom) do |request|
        # Custom authentication based on session metadata or request context
        session_id = request[:session_id] || "unknown"
        case session_id
        when "authenticated-session"
          { user_id: "stdio-user", role: "user" }
        when "admin-session"
          { user_id: "stdio-admin", role: "admin" }
        else
          false
        end
      end

      server.enable_authorization! do
        authorize_tools do |user, action, tool|
          case tool.name
          when "secure_tool"
            user && (user[:role] == "user" || user[:role] == "admin")
          else
            true
          end
        end
      end
    end

    describe "session-based authentication" do
      context "with authenticated session" do
        let(:request_context) { { session_id: "authenticated-session" } }

        it "successfully authenticates stdio requests" do
          result = server.security_middleware.process_request(request_context)

          expect(result[:success]).to be true
          expect(result[:session_context].authenticated?).to be true
          expect(result[:session_context].user[:user_id]).to eq("stdio-user")
          expect(result[:session_context].user[:role]).to eq("user")
        end
      end

      context "with admin session" do
        let(:request_context) { { session_id: "admin-session" } }

        it "authenticates with admin privileges" do
          result = server.security_middleware.process_request(request_context)

          expect(result[:success]).to be true
          expect(result[:session_context].user[:role]).to eq("admin")
        end
      end

      context "with unauthenticated session" do
        let(:request_context) { { session_id: "unknown-session" } }

        it "rejects authentication" do
          result = server.security_middleware.process_request(request_context)

          expect(result[:success]).to be false
          expect(result[:error]).to eq("Authentication required")
        end
      end
    end

    describe "tool access authorization" do
      let(:tool) { server.tools["secure_tool"] }

      context "with authenticated user" do
        let(:request_context) { { session_id: "authenticated-session" } }

        it "allows access to secure tools" do
          security_result = server.security_middleware.process_request(request_context)
          session_context = security_result[:session_context]

          authorization_result = server.security_middleware.authorize_action(
            session_context, :call, tool
          )

          expect(authorization_result).to be true
        end
      end

      context "with admin user" do
        let(:request_context) { { session_id: "admin-session" } }

        it "allows access to secure tools" do
          security_result = server.security_middleware.process_request(request_context)
          session_context = security_result[:session_context]

          authorization_result = server.security_middleware.authorize_action(
            session_context, :call, tool
          )

          expect(authorization_result).to be true
        end
      end

      context "with unauthenticated session" do
        let(:request_context) { { session_id: "unknown-session" } }

        it "denies access to secure tools" do
          security_result = server.security_middleware.process_request(request_context)

          expect(security_result[:success]).to be false
        end
      end
    end
  end

  describe "Cross-Transport Security Consistency" do
    let(:api_key) { "cross-transport-key" }

    before do
      server.enable_authentication!(strategy: :api_key, keys: [api_key])
      server.enable_authorization! do
        authorize_tools do |user, action, tool|
          user && user[:api_key] == "cross-transport-key"
        end
      end
    end

    describe "consistent authentication across transports" do
      let(:sse_request) do
        {
          "REQUEST_METHOD" => "POST",
          "HTTP_X_API_KEY" => api_key,
          "CONTENT_TYPE" => "application/json"
        }
      end

      let(:stdio_request) do
        { headers: { "X-API-Key" => api_key }, params: {} }
      end

      it "authenticates consistently across SSE and Stdio" do
        sse_result = server.security_middleware.process_request(sse_request)
        stdio_result = server.security_middleware.process_request(stdio_request)

        expect(sse_result[:success]).to be true
        expect(stdio_result[:success]).to be true

        expect(sse_result[:session_context].user[:api_key]).to eq(api_key)
        expect(stdio_result[:session_context].user[:api_key]).to eq(api_key)
      end
    end

    describe "consistent authorization across transports" do
      let(:tool) { server.tools["secure_tool"] }

      it "applies same authorization rules across transports" do
        sse_request = { 
          "REQUEST_METHOD" => "POST",
          "HTTP_X_API_KEY" => api_key 
        }
        stdio_request = { headers: { "X-API-Key" => api_key } }

        sse_security = server.security_middleware.process_request(sse_request)
        stdio_security = server.security_middleware.process_request(stdio_request)

        sse_auth = server.security_middleware.authorize_action(
          sse_security[:session_context], :call, tool
        )
        stdio_auth = server.security_middleware.authorize_action(
          stdio_security[:session_context], :call, tool
        )

        expect(sse_auth).to eq(stdio_auth)
        expect(sse_auth).to be true
      end
    end
  end

  describe "Security Error Handling" do
    before do
      server.enable_authentication!(strategy: :api_key, keys: ["valid-key"])
    end

    describe "malformed requests" do
      it "handles missing headers gracefully" do
        malformed_request = { params: {} }
        result = server.security_middleware.process_request(malformed_request)

        expect(result[:success]).to be false
        expect(result[:error]).to eq("Authentication required")
      end

      it "handles missing params gracefully" do
        malformed_request = { headers: {} }
        result = server.security_middleware.process_request(malformed_request)

        expect(result[:success]).to be false
        expect(result[:error]).to eq("Authentication required")
      end

      it "handles completely empty request" do
        result = server.security_middleware.process_request({})

        expect(result[:success]).to be false
        expect(result[:error]).to eq("Authentication required")
      end

      it "handles nil request gracefully" do
        result = server.security_middleware.process_request(nil)

        expect(result[:success]).to be false
        expect(result[:error]).to eq("Authentication required")
      end
    end

    describe "authentication strategy errors" do
      before do
        # Add a custom strategy that can raise errors
        server.enable_authentication!(strategy: :custom) do |request|
          case request[:headers]["X-Test-Header"]
          when "cause-error"
            raise StandardError, "Simulated authentication error"
          when "valid-auth"
            { user_id: "test-user" }
          else
            false
          end
        end
      end

      it "handles authentication strategy errors gracefully" do
        error_request = { headers: { "X-Test-Header" => "cause-error" } }
        result = server.security_middleware.process_request(error_request)

        expect(result[:success]).to be false
        expect(result[:error]).to eq("Authentication required")
      end

      it "continues to work after error recovery" do
        # First request causes error
        error_request = { headers: { "X-Test-Header" => "cause-error" } }
        server.security_middleware.process_request(error_request)

        # Second request should work normally
        valid_request = { headers: { "X-Test-Header" => "valid-auth" } }
        result = server.security_middleware.process_request(valid_request)

        expect(result[:success]).to be true
        expect(result[:session_context].authenticated?).to be true
      end
    end

    describe "authorization policy errors" do
      before do
        server.enable_authentication!(strategy: :api_key, keys: ["test-key"])
        server.enable_authorization! do
          authorize_tools do |user, action, tool|
            if tool.name == "error_tool"
              raise StandardError, "Policy evaluation error"
            else
              true
            end
          end
        end

        server.register_tool(
          name: "error_tool",
          description: "Tool that causes policy errors",
          input_schema: {}
        ) { "This tool causes policy errors" }
      end

      it "handles authorization policy errors gracefully" do
        request = { headers: { "X-API-Key" => "test-key" } }
        security_result = server.security_middleware.process_request(request)
        
        error_tool = server.tools["error_tool"]
        auth_result = server.security_middleware.authorize_action(
          security_result[:session_context], :call, error_tool
        )

        expect(auth_result).to be false
      end
    end
  end

  describe "Security Performance" do
    let(:api_keys) { (1..100).map { |i| "key-#{i}" } }

    before do
      server.enable_authentication!(strategy: :api_key, keys: api_keys)
    end

    it "handles multiple concurrent authentication requests efficiently" do
      requests = api_keys.first(10).map do |key|
        { headers: { "X-API-Key" => key } }
      end

      start_time = Time.now
      
      threads = requests.map do |request|
        Thread.new do
          server.security_middleware.process_request(request)
        end
      end

      results = threads.map(&:value)
      end_time = Time.now

      expect(results).to all(satisfy { |r| r[:success] == true })
      expect(end_time - start_time).to be < 1.0 # Should complete within 1 second
    end

    it "maintains consistent performance with large key sets" do
      large_request_count = 50
      requests = Array.new(large_request_count) do |i|
        { headers: { "X-API-Key" => api_keys[i % api_keys.length] } }
      end

      start_time = Time.now
      
      requests.each do |request|
        server.security_middleware.process_request(request)
      end
      
      end_time = Time.now

      # Performance should scale reasonably
      expect(end_time - start_time).to be < 2.0
    end
  end

  describe "Security Context Isolation" do
    before do
      server.enable_authentication!(strategy: :api_key, keys: ["user1-key", "user2-key"])
    end

    it "maintains separate security contexts for different requests" do
      user1_request = { headers: { "X-API-Key" => "user1-key" } }
      user2_request = { headers: { "X-API-Key" => "user2-key" } }

      user1_result = server.security_middleware.process_request(user1_request)
      user2_result = server.security_middleware.process_request(user2_request)

      expect(user1_result[:session_context].user[:api_key]).to eq("user1-key")
      expect(user2_result[:session_context].user[:api_key]).to eq("user2-key")

      # Contexts should be independent
      expect(user1_result[:session_context]).not_to eq(user2_result[:session_context])
      expect(user1_result[:session_context].object_id).not_to eq(user2_result[:session_context].object_id)
    end

    it "prevents context leakage between requests" do
      first_request = { headers: { "X-API-Key" => "user1-key" } }
      second_request = { headers: { "X-API-Key" => "user2-key" } }

      first_context = server.security_middleware.process_request(first_request)[:session_context]
      second_context = server.security_middleware.process_request(second_request)[:session_context]

      # Modify first context
      first_context.add_permission("test-permission")

      # Second context should not be affected
      expect(second_context.can?("test-permission")).to be false
      expect(first_context.can?("test-permission")).to be true
    end
  end
end