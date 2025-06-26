# frozen_string_literal: true

require "spec_helper"
require "vector_mcp/browser"
require "net/http"
require "json"

RSpec.describe "Browser Security Integration", type: :integration, :skip => "Integration tests require SSE transport implementation" do
  let(:server) { VectorMCP::Server.new("browser-security-test") }

  describe "Authentication Integration" do
    before do
      server.enable_authentication!(strategy: :api_key, keys: ["test-key-123", "admin-key-456"])
      server.register_browser_tools
    end

    context "without authentication" do
      it "denies browser commands when authentication is required" do
        http_server = VectorMCP::Browser::HttpServer.new(Logger.new(StringIO.new), 
                                                        security_middleware: server.security_middleware)
        
        env = {
          "REQUEST_METHOD" => "POST",
          "REMOTE_ADDR" => "127.0.0.1",
          "rack.input" => StringIO.new('{"url": "https://example.com"}')
        }

        response = http_server.send(:handle_navigate_command, env)
        expect(response[0]).to eq(401)
        
        body = JSON.parse(response[2][0])
        expect(body["error"]).to include("Authentication required")
      end
    end

    context "with valid authentication" do
      it "allows browser commands with valid API key" do
        http_server = VectorMCP::Browser::HttpServer.new(Logger.new(StringIO.new),
                                                        security_middleware: server.security_middleware)
        
        env = {
          "REQUEST_METHOD" => "POST",
          "REMOTE_ADDR" => "127.0.0.1",
          "HTTP_X_API_KEY" => "test-key-123",
          "rack.input" => StringIO.new('{"url": "https://example.com"}')
        }

        # Mock extension as connected
        http_server.instance_variable_set(:@extension_connected, true)
        http_server.instance_variable_set(:@extension_last_ping, Time.now)

        response = http_server.send(:handle_navigate_command, env)
        
        # Should not be authentication error (will be 408 timeout since no real extension)
        expect(response[0]).not_to eq(401)
        expect(response[0]).not_to eq(403)
      end
    end

    context "with invalid authentication" do
      it "denies browser commands with invalid API key" do
        http_server = VectorMCP::Browser::HttpServer.new(Logger.new(StringIO.new),
                                                        security_middleware: server.security_middleware)
        
        env = {
          "REQUEST_METHOD" => "POST",
          "REMOTE_ADDR" => "127.0.0.1",
          "HTTP_X_API_KEY" => "invalid-key",
          "rack.input" => StringIO.new('{"url": "https://example.com"}')
        }

        response = http_server.send(:handle_navigate_command, env)
        expect(response[0]).to eq(401)
      end
    end
  end

  describe "Authorization Integration" do
    before do
      server.enable_authentication!(strategy: :api_key, keys: ["admin-key", "user-key", "demo-key"])
      server.enable_authorization!
      server.register_browser_tools
      
      # Set up user roles based on API keys
      server.auth_manager.add_custom_auth do |request|
        api_key = request[:headers]["X-API-Key"]
        
        case api_key
        when "admin-key"
          {
            success: true,
            user: { id: "admin", role: "admin", permissions: ["*"] }
          }
        when "user-key"
          {
            success: true,
            user: { id: "user", role: "browser_user", permissions: ["browser_*"] }
          }
        when "demo-key"
          {
            success: true,
            user: { id: "demo", role: "demo", permissions: ["browser_navigate", "browser_snapshot"] }
          }
        else
          { success: false, error: "Invalid API key" }
        end
      end

      # Configure browser authorization
      server.enable_browser_authorization! do
        admin_full_access
        browser_user_full_access
        demo_user_limited_access
      end
    end

    it "allows admin users full access to all browser tools" do
      http_server = VectorMCP::Browser::HttpServer.new(Logger.new(StringIO.new),
                                                      security_middleware: server.security_middleware)
      
      # Mock extension connection
      http_server.instance_variable_set(:@extension_connected, true)
      http_server.instance_variable_set(:@extension_last_ping, Time.now)

      env = {
        "REQUEST_METHOD" => "POST",
        "REMOTE_ADDR" => "127.0.0.1",
        "HTTP_X_API_KEY" => "admin-key",
        "rack.input" => StringIO.new('{"url": "https://example.com"}')
      }

      response = http_server.send(:handle_navigate_command, env)
      expect(response[0]).not_to eq(403) # Not forbidden

      # Test click command
      env["rack.input"] = StringIO.new('{"selector": "button"}')
      response = http_server.send(:handle_click_command, env)
      expect(response[0]).not_to eq(403)
    end

    it "allows browser users access to all browser tools" do
      http_server = VectorMCP::Browser::HttpServer.new(Logger.new(StringIO.new),
                                                      security_middleware: server.security_middleware)
      
      http_server.instance_variable_set(:@extension_connected, true)
      http_server.instance_variable_set(:@extension_last_ping, Time.now)

      env = {
        "REQUEST_METHOD" => "POST",
        "REMOTE_ADDR" => "127.0.0.1",
        "HTTP_X_API_KEY" => "user-key",
        "rack.input" => StringIO.new('{"url": "https://example.com"}')
      }

      response = http_server.send(:handle_navigate_command, env)
      expect(response[0]).not_to eq(403)

      env["rack.input"] = StringIO.new('{"selector": "button"}')
      response = http_server.send(:handle_click_command, env)
      expect(response[0]).not_to eq(403)
    end

    it "restricts demo users to limited browser tools" do
      http_server = VectorMCP::Browser::HttpServer.new(Logger.new(StringIO.new),
                                                      security_middleware: server.security_middleware)
      
      http_server.instance_variable_set(:@extension_connected, true)
      http_server.instance_variable_set(:@extension_last_ping, Time.now)

      env_base = {
        "REQUEST_METHOD" => "POST",
        "REMOTE_ADDR" => "127.0.0.1",
        "HTTP_X_API_KEY" => "demo-key"
      }

      # Demo user should be able to navigate
      env = env_base.merge("rack.input" => StringIO.new('{"url": "https://example.com"}'))
      response = http_server.send(:handle_navigate_command, env)
      expect(response[0]).not_to eq(403)

      # Demo user should be able to take snapshots
      env = env_base.merge("rack.input" => StringIO.new('{}'))
      response = http_server.send(:handle_snapshot_command, env)
      expect(response[0]).not_to eq(403)

      # Demo user should NOT be able to click
      env = env_base.merge("rack.input" => StringIO.new('{"selector": "button"}'))
      response = http_server.send(:handle_click_command, env)
      expect(response[0]).to eq(403)

      # Demo user should NOT be able to type
      env = env_base.merge("rack.input" => StringIO.new('{"text": "hello", "selector": "input"}'))
      response = http_server.send(:handle_type_command, env)
      expect(response[0]).to eq(403)
    end
  end

  describe "Security Logging" do
    before do
      server.enable_authentication!(strategy: :api_key, keys: ["test-key"])
      server.enable_authorization!
      server.register_browser_tools
    end

    it "logs authentication attempts" do
      security_logger = Logger.new(StringIO.new)
      allow(VectorMCP).to receive(:logger_for).with("security.browser").and_return(security_logger)
      
      http_server = VectorMCP::Browser::HttpServer.new(Logger.new(StringIO.new),
                                                      security_middleware: server.security_middleware)

      env = {
        "REQUEST_METHOD" => "POST",
        "REMOTE_ADDR" => "127.0.0.1",
        "HTTP_X_API_KEY" => "test-key",
        "HTTP_USER_AGENT" => "TestAgent",
        "PATH_INFO" => "/browser/navigate",
        "rack.input" => StringIO.new('{"url": "https://example.com"}')
      }

      expect(security_logger).to receive(:info).with("Browser automation security check", 
        context: hash_including(:action, :ip_address, :user_agent))
      expect(security_logger).to receive(:info).with("Browser automation authorized",
        context: hash_including(:action, :ip_address))

      http_server.send(:check_security, env, :navigate)
    end

    it "logs authorization failures" do
      security_logger = Logger.new(StringIO.new)
      allow(VectorMCP).to receive(:logger_for).with("security.browser").and_return(security_logger)
      
      http_server = VectorMCP::Browser::HttpServer.new(Logger.new(StringIO.new),
                                                      security_middleware: server.security_middleware)

      env = {
        "REQUEST_METHOD" => "POST",
        "REMOTE_ADDR" => "127.0.0.1",
        "HTTP_X_API_KEY" => "invalid-key",
        "HTTP_USER_AGENT" => "TestAgent",
        "PATH_INFO" => "/browser/navigate"
      }

      expect(security_logger).to receive(:info).with("Browser automation security check", anything)
      expect(security_logger).to receive(:warn).with("Browser automation denied",
        context: hash_including(:error, :error_code, :ip_address))

      http_server.send(:check_security, env, :navigate)
    end

    it "logs command execution with user context" do
      security_logger = Logger.new(StringIO.new)
      allow(VectorMCP).to receive(:logger_for).with("security.browser").and_return(security_logger)
      
      server.auth_manager.add_custom_auth do |request|
        api_key = request[:headers]["X-API-Key"]
        if api_key == "test-key"
          {
            success: true,
            user: { id: "test_user", role: "browser_user" }
          }
        else
          { success: false, error: "Invalid key" }
        end
      end

      http_server = VectorMCP::Browser::HttpServer.new(Logger.new(StringIO.new),
                                                      security_middleware: server.security_middleware)
      
      command_queue = instance_double("CommandQueue")
      allow(http_server).to receive(:command_queue).and_return(command_queue)
      allow(command_queue).to receive(:enqueue_command)
      allow(command_queue).to receive(:wait_for_result).and_return({ success: true, result: {} })

      env = {
        "REQUEST_METHOD" => "POST",
        "REMOTE_ADDR" => "127.0.0.1",
        "HTTP_X_API_KEY" => "test-key",
        "rack.input" => StringIO.new('{"url": "https://example.com"}')
      }

      expect(security_logger).to receive(:info).with("Browser command executed",
        context: hash_including(:user_id => "test_user", :user_role => "browser_user"))
      expect(security_logger).to receive(:info).with("Browser command completed",
        context: hash_including(:user_id => "test_user"))

      http_server.send(:execute_browser_command, env, "navigate")
    end
  end

  describe "Security Opt-out" do
    it "allows browser automation when security is disabled" do
      server_no_security = VectorMCP::Server.new("no-security-test")
      server_no_security.register_browser_tools

      http_server = VectorMCP::Browser::HttpServer.new(Logger.new(StringIO.new),
                                                      security_middleware: server_no_security.security_middleware)

      # Mock extension connection
      http_server.instance_variable_set(:@extension_connected, true)
      http_server.instance_variable_set(:@extension_last_ping, Time.now)

      env = {
        "REQUEST_METHOD" => "POST",
        "REMOTE_ADDR" => "127.0.0.1",
        "rack.input" => StringIO.new('{"url": "https://example.com"}')
        # No authentication headers
      }

      response = http_server.send(:handle_navigate_command, env)
      
      # Should not be authentication/authorization error
      expect(response[0]).not_to eq(401)
      expect(response[0]).not_to eq(403)
    end
  end

  describe "Parameter Sanitization" do
    it "sanitizes sensitive parameters in logs" do
      http_server = VectorMCP::Browser::HttpServer.new(Logger.new(StringIO.new))

      params = {
        "url" => "https://example.com",
        "password" => "secret123",
        "token" => "abc123"
      }

      sanitized = http_server.send(:sanitize_params_for_logging, params)
      
      expect(sanitized["url"]).to eq("https://example.com")
      expect(sanitized["password"]).to eq("[REDACTED]")
      expect(sanitized["token"]).to eq("[REDACTED]")
    end

    it "truncates long text values" do
      http_server = VectorMCP::Browser::HttpServer.new(Logger.new(StringIO.new))

      long_text = "A" * 1500
      params = { "text" => long_text }

      sanitized = http_server.send(:sanitize_params_for_logging, params)
      
      expect(sanitized["text"]).to include("[TRUNCATED]")
      expect(sanitized["text"].length).to be < long_text.length
    end
  end

  describe "Extension Connection Security" do
    it "logs extension connection events" do
      security_logger = Logger.new(StringIO.new)
      allow(VectorMCP).to receive(:logger_for).with("security.browser").and_return(security_logger)
      
      http_server = VectorMCP::Browser::HttpServer.new(Logger.new(StringIO.new))

      env = {
        "REQUEST_METHOD" => "POST",
        "REMOTE_ADDR" => "192.168.1.100",
        "HTTP_USER_AGENT" => "Chrome Extension/1.0"
      }

      expect(security_logger).to receive(:info).with("Chrome extension connected",
        context: hash_including(
          ip_address: "192.168.1.100",
          user_agent: "Chrome Extension/1.0"
        ))

      http_server.send(:handle_extension_ping, env)
    end

    it "logs extension disconnection events" do
      security_logger = Logger.new(StringIO.new)
      allow(VectorMCP).to receive(:logger_for).with("security.browser").and_return(security_logger)
      
      http_server = VectorMCP::Browser::HttpServer.new(Logger.new(StringIO.new))

      # Set up extension as previously connected but timed out
      http_server.instance_variable_set(:@extension_connected, true)
      http_server.instance_variable_set(:@extension_last_ping, Time.now - 35)

      expect(security_logger).to receive(:warn).with("Chrome extension disconnected",
        context: hash_including(:last_ping, :timeout_seconds))

      http_server.extension_connected?
    end
  end
end