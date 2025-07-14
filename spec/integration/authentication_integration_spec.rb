# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Authentication Integration" do
  let(:server) { VectorMCP::Server.new(name: "AuthTestServer", version: "1.0.0") }
  let(:session) { VectorMCP::Session.new(server, nil, id: "test-session") }

  before do
    # Register a test tool
    server.register_tool(
      name: "test_tool",
      description: "A test tool",
      input_schema: {
        type: "object",
        properties: { message: { type: "string" } },
        required: ["message"]
      }
    ) { |args| "Tool executed with: #{args["message"]}" }

    # Initialize session
    session.initialize!({
                          "protocolVersion" => "2024-11-05",
                          "capabilities" => {},
                          "clientInfo" => { "name" => "test-client", "version" => "1.0.0" }
                        })
  end

  context "without authentication enabled" do
    it "allows tool access without credentials" do
      # Call tool without any authentication
      result = server.handle_message({
                                       "jsonrpc" => "2.0",
                                       "id" => 1,
                                       "method" => "tools/call",
                                       "params" => {
                                         "name" => "test_tool",
                                         "arguments" => { "message" => "hello" }
                                       }
                                     }, session, "test-session")

      expect(result[:isError]).to be false
      expect(result[:content][0][:text]).to include("Tool executed with: hello")
    end
  end

  context "with API key authentication enabled" do
    before do
      server.enable_authentication!(
        strategy: :api_key,
        keys: %w[valid-key-123 admin-key-456]
      )
    end

    it "rejects tool access without valid API key" do
      # Session has default empty request context (no authentication headers)

      expect do
        server.handle_message({
                                "jsonrpc" => "2.0",
                                "id" => 1,
                                "method" => "tools/call",
                                "params" => {
                                  "name" => "test_tool",
                                  "arguments" => { "message" => "hello" }
                                }
                              }, session, "test-session")
      end.to raise_error(VectorMCP::UnauthorizedError, "Authentication required")
    end

    it "allows tool access with valid API key" do
      # Set session request context with valid API key
      session.set_request_context({
        headers: { "X-API-Key" => "valid-key-123" },
        params: {}
      })

      result = server.handle_message({
                                       "jsonrpc" => "2.0",
                                       "id" => 1,
                                       "method" => "tools/call",
                                       "params" => {
                                         "name" => "test_tool",
                                         "arguments" => { "message" => "authenticated hello" }
                                       }
                                     }, session, "test-session")

      expect(result[:isError]).to be false
      expect(result[:content][0][:text]).to include("Tool executed with: authenticated hello")
    end

    it "rejects tool access with invalid API key" do
      # Set session request context with invalid API key
      session.set_request_context({
        headers: { "X-API-Key" => "invalid-key" },
        params: {}
      })

      expect do
        server.handle_message({
                                "jsonrpc" => "2.0",
                                "id" => 1,
                                "method" => "tools/call",
                                "params" => {
                                  "name" => "test_tool",
                                  "arguments" => { "message" => "hello" }
                                }
                              }, session, "test-session")
      end.to raise_error(VectorMCP::UnauthorizedError, "Authentication required")
    end
  end

  context "with authorization policies enabled" do
    before do
      server.enable_authentication!(
        strategy: :api_key,
        keys: %w[user-key admin-key]
      )

      server.enable_authorization! do
        authorize_tools do |user, _action, tool|
          case tool.name
          when "test_tool"
            # Only allow admin key
            user&.dig(:api_key) == "admin-key"
          else
            true
          end
        end
      end
    end

    it "allows access with authorized user" do
      # Set session request context with admin API key
      session.set_request_context({
        headers: { "X-API-Key" => "admin-key" },
        params: {}
      })

      result = server.handle_message({
                                       "jsonrpc" => "2.0",
                                       "id" => 1,
                                       "method" => "tools/call",
                                       "params" => {
                                         "name" => "test_tool",
                                         "arguments" => { "message" => "admin access" }
                                       }
                                     }, session, "test-session")

      expect(result[:isError]).to be false
      expect(result[:content][0][:text]).to include("Tool executed with: admin access")
    end

    it "denies access to unauthorized user" do
      # Set session request context with user API key (not admin)
      session.set_request_context({
        headers: { "X-API-Key" => "user-key" },
        params: {}
      })

      expect do
        server.handle_message({
                                "jsonrpc" => "2.0",
                                "id" => 1,
                                "method" => "tools/call",
                                "params" => {
                                  "name" => "test_tool",
                                  "arguments" => { "message" => "user access" }
                                }
                              }, session, "test-session")
      end.to raise_error(VectorMCP::ForbiddenError, "Access denied")
    end
  end

  context "security status" do
    it "reports security disabled by default" do
      status = server.security_status

      expect(status[:authentication][:enabled]).to be false
      expect(status[:authorization][:enabled]).to be false
      expect(status[:authentication][:strategies]).to be_empty
    end

    it "reports security enabled when configured" do
      server.enable_authentication!(strategy: :api_key, keys: ["test-key"])
      server.enable_authorization!

      status = server.security_status

      expect(status[:authentication][:enabled]).to be true
      expect(status[:authorization][:enabled]).to be true
      expect(status[:authentication][:strategies]).to include(:api_key)
      expect(status[:authentication][:default_strategy]).to eq(:api_key)
    end
  end
end
