# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Security Error Handling and Edge Cases" do
  let(:server) { VectorMCP::Server.new(name: "ErrorTestServer", version: "1.0.0") }
  let(:logger_double) { instance_double("Logger", info: nil, debug: nil, warn: nil, error: nil, fatal: nil, level: nil) }

  before do
    allow(logger_double).to receive(:level=)
    allow(VectorMCP).to receive(:logger).and_return(logger_double)
  end

  describe "Authentication Strategy Error Recovery" do
    describe "API Key strategy with malformed data" do
      before do
        server.enable_authentication!(strategy: :api_key, keys: ["valid-key"])
      end

      it "handles extremely long API keys gracefully" do
        long_key = "a" * 10_000
        request = { headers: { "X-API-Key" => long_key } }

        result = server.security_middleware.process_request(request)

        expect(result[:success]).to be false
        expect(result[:error]).to eq("Authentication required")
      end

      it "handles API keys with special characters" do
        special_key = "key-with-symbols!@#$%^&*()_+-=[]{}|;:,.<>?"
        request = { headers: { "X-API-Key" => special_key } }

        result = server.security_middleware.process_request(request)

        expect(result[:success]).to be false
        expect(result[:error]).to eq("Authentication required")
      end

      it "handles API keys with unicode characters" do
        unicode_key = "key-with-unicode-🔑-characters"
        request = { headers: { "X-API-Key" => unicode_key } }

        result = server.security_middleware.process_request(request)

        expect(result[:success]).to be false
        expect(result[:error]).to eq("Authentication required")
      end

      it "handles null bytes in API keys" do
        null_key = "key\x00with\x00nulls"
        request = { headers: { "X-API-Key" => null_key } }

        result = server.security_middleware.process_request(request)

        expect(result[:success]).to be false
        expect(result[:error]).to eq("Authentication required")
      end

      it "handles binary data as API keys" do
        binary_key = "\x80\x81\x82\x83\x84\x85"
        request = { headers: { "X-API-Key" => binary_key } }

        result = server.security_middleware.process_request(request)

        expect(result[:success]).to be false
        expect(result[:error]).to eq("Authentication required")
      end
    end

    describe "Custom strategy error scenarios" do
      context "with database connection failures" do
        before do
          server.enable_authentication!(strategy: :custom) do |request|
            if request[:headers]["X-Simulate-DB-Error"]
              raise StandardError, "Database connection failed"
            elsif request[:headers]["X-Valid-Token"]
              { user_id: "test-user" }
            else
              false
            end
          end
        end

        it "handles database errors gracefully" do
          error_request = { headers: { "X-Simulate-DB-Error" => "true" } }
          result = server.security_middleware.process_request(error_request)

          expect(result[:success]).to be false
          expect(result[:error]).to eq("Authentication required")
        end

        it "recovers from errors for subsequent requests" do
          # First request fails
          error_request = { headers: { "X-Simulate-DB-Error" => "true" } }
          server.security_middleware.process_request(error_request)

          # Second request succeeds
          valid_request = { headers: { "X-Valid-Token" => "true" } }
          result = server.security_middleware.process_request(valid_request)

          expect(result[:success]).to be true
          expect(result[:session_context].authenticated?).to be true
        end
      end

      context "with timeout scenarios" do
        before do
          server.enable_authentication!(strategy: :custom) do |request|
            if request[:headers]["X-Simulate-Timeout"]
              sleep(0.1) # Simulate slow operation
              raise Timeout::Error, "Authentication timeout"
            else
              { user_id: "fast-user" }
            end
          end
        end

        it "handles timeout errors gracefully" do
          timeout_request = { headers: { "X-Simulate-Timeout" => "true" } }

          expect do
            result = server.security_middleware.process_request(timeout_request)
            expect(result[:success]).to be false
          end.not_to raise_error
        end
      end

      context "with memory exhaustion scenarios" do
        before do
          server.enable_authentication!(strategy: :custom) do |request|
            raise NoMemoryError, "Out of memory" if request[:headers]["X-Simulate-Memory-Error"]

            { user_id: "normal-user" }
          end
        end

        it "handles memory errors gracefully" do
          memory_error_request = { headers: { "X-Simulate-Memory-Error" => "true" } }

          expect do
            result = server.security_middleware.process_request(memory_error_request)
            expect(result[:success]).to be false
          end.not_to raise_error
        end
      end
    end
  end

  describe "Authorization Policy Error Recovery" do
    before do
      server.enable_authentication!(strategy: :api_key, keys: ["test-key"])

      server.register_tool(
        name: "normal_tool",
        description: "A normal tool",
        input_schema: {}
      ) { "Normal response" }

      server.register_tool(
        name: "error_prone_tool",
        description: "A tool that causes policy errors",
        input_schema: {}
      ) { "Error prone response" }
    end

    describe "policy execution failures" do
      before do
        server.enable_authorization! do
          authorize_tools do |_user, _action, tool|
            case tool.name
            when "error_prone_tool"
              raise StandardError, "Policy database is down"
            when "normal_tool"
              true
            else
              false
            end
          end
        end
      end

      it "denies access when policy raises an error" do
        request = { headers: { "X-API-Key" => "test-key" } }
        security_result = server.security_middleware.process_request(request)

        error_tool = server.tools["error_prone_tool"]
        auth_result = server.security_middleware.authorize_action(
          security_result[:session_context], :call, error_tool
        )

        expect(auth_result).to be false
      end

      it "continues to work for other tools after policy error" do
        request = { headers: { "X-API-Key" => "test-key" } }
        security_result = server.security_middleware.process_request(request)
        session_context = security_result[:session_context]

        # First tool causes error
        error_tool = server.tools["error_prone_tool"]
        error_auth = server.security_middleware.authorize_action(
          session_context, :call, error_tool
        )

        # Second tool should work normally
        normal_tool = server.tools["normal_tool"]
        normal_auth = server.security_middleware.authorize_action(
          session_context, :call, normal_tool
        )

        expect(error_auth).to be false
        expect(normal_auth).to be true
      end
    end

    describe "policy resource type determination errors" do
      before do
        server.enable_authentication!(strategy: :api_key, keys: ["test-key"])
        server.enable_authorization! do
          authorize_tools do |_user, _action, tool|
            # Simulate error when accessing tool properties
            raise NoMethodError, "Tool object is corrupted" if tool.respond_to?(:name) && tool.name == "corrupted_tool"

            true
          end
        end

        # Create a corrupted tool-like object that behaves like a VectorMCP::Definitions::Tool
        corrupted_tool = double("corrupted_tool")
        allow(corrupted_tool).to receive(:name).and_raise(NoMethodError, "Object is corrupted")
        allow(corrupted_tool).to receive(:is_a?).with(VectorMCP::Definitions::Tool).and_return(true)
        # Make it pass the case statement check
        allow(VectorMCP::Definitions::Tool).to receive(:===).with(corrupted_tool).and_return(true)
        server.tools["corrupted_tool"] = corrupted_tool
      end

      it "handles corrupted tool objects gracefully" do
        request = { headers: { "X-API-Key" => "test-key" } }
        security_result = server.security_middleware.process_request(request)

        corrupted_tool = server.tools["corrupted_tool"]
        auth_result = server.security_middleware.authorize_action(
          security_result[:session_context], :call, corrupted_tool
        )

        expect(auth_result).to be false
      end
    end
  end

  describe "Session Context Edge Cases" do
    describe "user data corruption" do
      before do
        server.enable_authentication!(strategy: :custom) do |request|
          case request[:headers]["X-User-Type"]
          when "nil_user"
            { user: nil }
          when "empty_user"
            { user: {} }
          when "string_user"
            { user: "just_a_string" }
          when "array_user"
            { user: %w[invalid array] }
          when "circular_reference"
            circular = {}
            circular[:self] = circular
            { user: circular }
          else
            { user: { id: 123 } }
          end
        end
      end

      it "handles nil user data gracefully" do
        request = { headers: { "X-User-Type" => "nil_user" } }
        result = server.security_middleware.process_request(request)

        expect(result[:success]).to be true
        expect(result[:session_context].user).to be_nil
        expect(result[:session_context].user_identifier).to eq("anonymous")
      end

      it "handles empty user data gracefully" do
        request = { headers: { "X-User-Type" => "empty_user" } }
        result = server.security_middleware.process_request(request)

        expect(result[:success]).to be true
        expect(result[:session_context].user).to eq({})
        expect(result[:session_context].user_identifier).to eq("authenticated_user")
      end

      it "handles string user data gracefully" do
        request = { headers: { "X-User-Type" => "string_user" } }
        result = server.security_middleware.process_request(request)

        expect(result[:success]).to be true
        expect(result[:session_context].user).to eq("just_a_string")
        expect(result[:session_context].user_identifier).to eq("just_a_string")
      end

      it "handles array user data gracefully" do
        request = { headers: { "X-User-Type" => "array_user" } }
        result = server.security_middleware.process_request(request)

        expect(result[:success]).to be true
        expect(result[:session_context].user).to eq(%w[invalid array])
        expect(result[:session_context].user_identifier).to eq("authenticated_user")
      end

      it "handles circular reference user data" do
        request = { headers: { "X-User-Type" => "circular_reference" } }

        expect do
          result = server.security_middleware.process_request(request)
          expect(result[:success]).to be true
        end.not_to raise_error
      end
    end

    describe "permission management edge cases" do
      let(:session_context) { VectorMCP::Security::SessionContext.new }

      it "handles extremely large permission sets" do
        large_permissions = (1..10_000).map { |i| "permission_#{i}" }

        expect do
          session_context.add_permissions(large_permissions)
        end.not_to raise_error

        expect(session_context.permissions.size).to eq(10_000)
        expect(session_context.can?("permission_5000")).to be true
      end

      it "handles permissions with special characters" do
        special_permissions = [
          "read:files/*",
          "write:configs/app.json",
          "admin:users@domain.com",
          "execute:scripts/*.sh",
          "access:api/v1/**"
        ]

        session_context.add_permissions(special_permissions)

        special_permissions.each do |permission|
          expect(session_context.can?(permission)).to be true
        end
      end

      it "handles unicode permissions" do
        unicode_permissions = %w[
          读取文件
          書き込み権限
          administración
          доступ_к_файлам
        ]

        session_context.add_permissions(unicode_permissions)

        unicode_permissions.each do |permission|
          expect(session_context.can?(permission)).to be true
        end
      end

      it "handles extremely long permission names" do
        long_permission = "a" * 1000

        expect do
          session_context.add_permission(long_permission)
        end.not_to raise_error

        expect(session_context.can?(long_permission)).to be true
      end
    end
  end

  describe "Middleware Error Propagation" do
    before do
      server.enable_authentication!(strategy: :api_key, keys: ["test-key"])
    end

    describe "request normalization errors" do
      it "handles non-hash, non-rack request objects" do
        invalid_requests = [
          "string_request",
          123,
          [],
          Object.new,
          nil
        ]

        invalid_requests.each do |invalid_request|
          result = server.security_middleware.process_request(invalid_request)

          expect(result[:success]).to be false
          expect(result[:error]).to eq("Authentication required")
        end
      end

      it "handles requests with nil values for required fields" do
        requests_with_nils = [
          { headers: nil, params: {} },
          { headers: {}, params: nil },
          { headers: nil, params: nil }
        ]

        requests_with_nils.each do |request|
          result = server.security_middleware.process_request(request)

          expect(result[:success]).to be false
          expect(result[:error]).to eq("Authentication required")
        end
      end
    end

    describe "concurrent error scenarios" do
      before do
        server.enable_authentication!(strategy: :custom) do |_request|
          # Simulate random failures in 30% of requests
          raise StandardError, "Random authentication failure" if rand < 0.3

          { user_id: Thread.current.object_id }
        end
      end

      it "handles concurrent authentication failures gracefully" do
        threads = 20.times.map do |i|
          Thread.new do
            request = { headers: { "request_id" => i.to_s } }
            server.security_middleware.process_request(request)
          end
        end

        results = threads.map(&:value)

        # Some should succeed, some should fail, but none should raise errors
        expect(results).to all(be_a(Hash))
        expect(results).to all(have_key(:success))

        successful = results.count { |r| r[:success] }
        failed = results.count { |r| !r[:success] }

        expect(successful).to be > 0
        expect(failed).to be > 0
        expect(successful + failed).to eq(20)
      end
    end
  end

  describe "Security Configuration Edge Cases" do
    describe "authentication strategy conflicts" do
      it "handles multiple enable calls gracefully" do
        expect do
          server.enable_authentication!(strategy: :api_key, keys: ["key1"])
          server.enable_authentication!(strategy: :api_key, keys: ["key2"])
          server.enable_authentication!(strategy: :api_key, keys: ["key3"])
        end.not_to raise_error

        # Should use the last configuration
        strategy = server.auth_manager.strategies[:api_key]
        expect(strategy.valid_keys).to include("key3")
      end

      it "handles switching between different strategies" do
        server.enable_authentication!(strategy: :api_key, keys: ["api-key"])

        server.enable_authentication!(strategy: :custom) do |_request|
          { user_id: "custom-user" }
        end

        # Should now use custom strategy
        request = { headers: {} }
        result = server.security_middleware.process_request(request)

        expect(result[:success]).to be true
        expect(result[:session_context].user[:user_id]).to eq("custom-user")
      end
    end

    describe "authorization policy conflicts" do
      before do
        server.enable_authentication!(strategy: :api_key, keys: ["test-key"])

        server.register_tool(
          name: "conflict_tool",
          description: "Tool to test policy conflicts",
          input_schema: {}
        ) { "Response" }
      end

      it "handles multiple authorization policy registrations" do
        expect do
          server.enable_authorization! do
            authorize_tools { |_user, _action, _tool| true }
          end

          server.enable_authorization! do
            authorize_tools { |_user, _action, _tool| false }
          end

          server.enable_authorization! do
            authorize_tools { |user, _action, _tool| user && true }
          end
        end.not_to raise_error

        # Should use the last policy
        request = { headers: { "X-API-Key" => "test-key" } }
        security_result = server.security_middleware.process_request(request)

        tool = server.tools["conflict_tool"]
        auth_result = server.security_middleware.authorize_action(
          security_result[:session_context], :call, tool
        )

        expect(auth_result).to be true # user && true should be true
      end
    end

    describe "empty configuration edge cases" do
      it "handles authentication with empty key list" do
        server.enable_authentication!(strategy: :api_key, keys: [])

        request = { headers: { "X-API-Key" => "any-key" } }
        result = server.security_middleware.process_request(request)

        expect(result[:success]).to be false
        expect(result[:error]).to eq("Authentication required")
      end

      it "handles authorization with no policies defined" do
        server.enable_authentication!(strategy: :api_key, keys: ["test-key"])
        server.enable_authorization! # No policies defined

        request = { headers: { "X-API-Key" => "test-key" } }
        security_result = server.security_middleware.process_request(request)

        # Create a dummy tool
        dummy_tool = VectorMCP::Definitions::Tool.new(
          name: "dummy", description: "Test", input_schema: {}, handler: proc {}
        )

        auth_result = server.security_middleware.authorize_action(
          security_result[:session_context], :call, dummy_tool
        )

        # Should allow access when no policy is defined (opt-in)
        expect(auth_result).to be true
      end
    end
  end

  describe "Memory and Resource Management" do
    describe "session context memory usage" do
      it "handles large numbers of session contexts without memory leaks" do
        server.enable_authentication!(strategy: :api_key, keys: ["test-key"])

        initial_memory = GC.stat(:total_allocated_objects)

        # Create many session contexts
        1000.times do |i|
          request = { headers: { "X-API-Key" => "test-key", "Request-ID" => i.to_s } }
          server.security_middleware.process_request(request)
        end

        # Force garbage collection
        GC.start

        final_memory = GC.stat(:total_allocated_objects)
        memory_growth = final_memory - initial_memory

        # Memory growth should be reasonable (allowing for some test overhead)
        expect(memory_growth).to be < 50_000
      end
    end

    describe "authentication strategy cleanup" do
      it "properly cleans up resources when switching strategies" do
        # Start with API key
        server.enable_authentication!(strategy: :api_key, keys: (1..1000).map(&:to_s))

        # Switch to custom strategy
        server.enable_authentication!(strategy: :custom) do |_request|
          { user_id: "test" }
        end

        # Old API key strategy should be cleaned up
        expect(server.auth_manager.strategies.keys).to eq([:custom])
      end
    end
  end
end
