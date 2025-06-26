# frozen_string_literal: true

require "spec_helper"
require "vector_mcp/browser"

RSpec.describe VectorMCP::Browser::HttpServer do
  let(:logger) { Logger.new(StringIO.new) }
  let(:security_middleware) { nil }
  let(:server) { described_class.new(logger, security_middleware: security_middleware) }

  describe "#initialize" do
    it "initializes with logger" do
      expect(server.logger).to eq(logger)
    end

    it "initializes command queue" do
      expect(server.command_queue).to be_a(VectorMCP::Browser::CommandQueue)
    end

    it "starts with extension disconnected" do
      expect(server.extension_connected?).to be(false)
    end
  end

  describe "#extension_connected?" do
    context "when extension never connected" do
      it "returns false" do
        expect(server.extension_connected?).to be(false)
      end
    end

    context "when extension recently connected" do
      before do
        # Simulate extension ping
        env = { "REQUEST_METHOD" => "POST", "REMOTE_ADDR" => "127.0.0.1" }
        server.send(:handle_extension_ping, env)
      end

      it "returns true" do
        expect(server.extension_connected?).to be(true)
      end
    end

    context "when extension connection timed out" do
      before do
        server.instance_variable_set(:@extension_connected, true)
        server.instance_variable_set(:@extension_last_ping, Time.now - 35) # 35 seconds ago
      end

      it "returns false" do
        expect(server.extension_connected?).to be(false)
      end

      it "logs disconnection event" do
        security_logger = double("VectorMCP Security Logger").tap do |mock|
          allow(mock).to receive(:info)
          allow(mock).to receive(:warn)
          allow(mock).to receive(:error)
          allow(mock).to receive(:debug)
        end
        allow(VectorMCP).to receive(:logger_for).with("security.browser").and_return(security_logger)
        
        expect(security_logger).to receive(:warn).with("Chrome extension disconnected", context: hash_including(:last_ping, :timeout_seconds))
        
        server.extension_connected?
      end
    end
  end

  describe "#handle_browser_request" do
    let(:env) { { "REQUEST_METHOD" => "POST", "PATH_INFO" => "/browser/ping" } }

    context "with valid browser endpoints" do
      it "routes to ping handler" do
        expect(server).to receive(:handle_extension_ping).with(env)
        server.handle_browser_request("/browser/ping", env)
      end

      it "routes to poll handler" do
        expect(server).to receive(:handle_extension_poll).with(env)
        server.handle_browser_request("/browser/poll", env)
      end

      it "routes to result handler" do
        expect(server).to receive(:handle_extension_result).with(env)
        server.handle_browser_request("/browser/result", env)
      end

      it "routes to navigate handler" do
        expect(server).to receive(:handle_navigate_command).with(env)
        server.handle_browser_request("/browser/navigate", env)
      end

      it "routes to click handler" do
        expect(server).to receive(:handle_click_command).with(env)
        server.handle_browser_request("/browser/click", env)
      end

      it "routes to type handler" do
        expect(server).to receive(:handle_type_command).with(env)
        server.handle_browser_request("/browser/type", env)
      end

      it "routes to snapshot handler" do
        expect(server).to receive(:handle_snapshot_command).with(env)
        server.handle_browser_request("/browser/snapshot", env)
      end

      it "routes to screenshot handler" do
        expect(server).to receive(:handle_screenshot_command).with(env)
        server.handle_browser_request("/browser/screenshot", env)
      end

      it "routes to console handler" do
        expect(server).to receive(:handle_console_command).with(env)
        server.handle_browser_request("/browser/console", env)
      end

      it "routes to wait handler" do
        expect(server).to receive(:handle_wait_command).with(env)
        server.handle_browser_request("/browser/wait", env)
      end
    end

    context "with invalid endpoint" do
      it "returns 404 for unknown endpoint" do
        response = server.handle_browser_request("/browser/unknown", env)
        expect(response[0]).to eq(404)
        expect(response[2]).to eq(["Browser endpoint not found"])
      end
    end
  end

  describe "#check_security" do
    let(:env) { { "REMOTE_ADDR" => "127.0.0.1", "HTTP_USER_AGENT" => "Test" } }

    context "without security middleware" do
      it "returns success" do
        result = server.send(:check_security, env, :navigate)
        expect(result[:success]).to be(true)
      end
    end

    context "with security middleware disabled" do
      let(:security_middleware) { instance_double("SecurityMiddleware", security_enabled?: false) }

      it "returns success" do
        result = server.send(:check_security, env, :navigate)
        expect(result[:success]).to be(true)
      end
    end

    context "with security middleware enabled" do
      let(:security_middleware) do
        instance_double("SecurityMiddleware", 
                       security_enabled?: true,
                       normalize_request: { headers: {}, params: {} },
                       process_request: { success: true })
      end

      before do
        mock_queue_logger = double("VectorMCP Queue Logger").tap do |mock|
          allow(mock).to receive(:info)
          allow(mock).to receive(:warn)
          allow(mock).to receive(:error)
          allow(mock).to receive(:debug)
        end
        mock_security_logger = double("VectorMCP Security Logger").tap do |mock|
          allow(mock).to receive(:info)
          allow(mock).to receive(:warn)
          allow(mock).to receive(:error)
          allow(mock).to receive(:debug)
        end
        
        allow(VectorMCP).to receive(:logger_for).with("browser.queue").and_return(mock_queue_logger)
        allow(VectorMCP).to receive(:logger_for).with("security.browser").and_return(mock_security_logger)
        
        # Set the security logger for this context
        @mock_security_logger = mock_security_logger
      end

      it "processes request through security middleware" do
        expect(security_middleware).to receive(:normalize_request).with(env)
        expect(security_middleware).to receive(:process_request)
        
        server.send(:check_security, env, :navigate)
      end

      it "logs security check" do
        expect(@mock_security_logger).to receive(:info).with("Browser automation security check", context: hash_including(:action, :ip_address))
        
        server.send(:check_security, env, :navigate)
      end
    end
  end

  describe "browser command handlers" do
    let(:env) do
      {
        "REQUEST_METHOD" => "POST",
        "REMOTE_ADDR" => "127.0.0.1",
        "rack.input" => StringIO.new('{"url": "https://example.com"}')
      }
    end

    before do
      # Mock extension as connected
      server.instance_variable_set(:@extension_connected, true)
      server.instance_variable_set(:@extension_last_ping, Time.now)
    end

    describe "#handle_navigate_command" do
      it "requires POST method" do
        env["REQUEST_METHOD"] = "GET"
        response = server.send(:handle_navigate_command, env)
        expect(response[0]).to eq(405)
      end

      it "requires extension connection" do
        server.instance_variable_set(:@extension_connected, false)
        response = server.send(:handle_navigate_command, env)
        expect(response[0]).to eq(503)
      end

      it "executes browser command when conditions are met" do
        allow(server).to receive(:check_security).and_return({ success: true })
        expect(server).to receive(:execute_browser_command).with(env, "navigate")
        
        server.send(:handle_navigate_command, env)
      end

      context "with security enabled" do
        let(:security_middleware) { instance_double("SecurityMiddleware", security_enabled?: true) }

        it "checks security before execution" do
          expect(server).to receive(:check_security).with(env, :navigate).and_return({ success: true })
          expect(server).to receive(:execute_browser_command)
          
          server.send(:handle_navigate_command, env)
        end

        it "returns security error on failure" do
          expect(server).to receive(:check_security).and_return({ 
            success: false, 
            error: "Unauthorized", 
            error_code: "AUTHENTICATION_REQUIRED" 
          })
          expect(server).to receive(:security_error_response)
          
          server.send(:handle_navigate_command, env)
        end
      end
    end

    describe "#handle_click_command" do
      let(:env) do
        {
          "REQUEST_METHOD" => "POST",
          "REMOTE_ADDR" => "127.0.0.1",
          "rack.input" => StringIO.new('{"selector": "button"}')
        }
      end

      it "executes click command" do
        allow(server).to receive(:check_security).and_return({ success: true })
        expect(server).to receive(:execute_browser_command).with(env, "click")
        
        server.send(:handle_click_command, env)
      end
    end

    describe "#handle_type_command" do
      let(:env) do
        {
          "REQUEST_METHOD" => "POST",
          "REMOTE_ADDR" => "127.0.0.1",
          "rack.input" => StringIO.new('{"text": "hello", "selector": "input"}')
        }
      end

      it "executes type command" do
        allow(server).to receive(:check_security).and_return({ success: true })
        expect(server).to receive(:execute_browser_command).with(env, "type")
        
        server.send(:handle_type_command, env)
      end
    end
  end

  describe "#execute_browser_command" do
    let(:env) do
      {
        "REQUEST_METHOD" => "POST",
        "REMOTE_ADDR" => "127.0.0.1",
        "rack.input" => StringIO.new('{"url": "https://example.com"}')
      }
    end

    let(:command_queue) { instance_double("CommandQueue") }

    before do
      allow(server).to receive(:command_queue).and_return(command_queue)
      allow(server).to receive(:extract_user_context_from_env).and_return({ user_id: "test_user", user_role: "admin" })
      allow(VectorMCP).to receive(:logger_for).with("security.browser").and_return(logger)
    end

    it "enqueues command to queue" do
      expect(command_queue).to receive(:enqueue_command).with(hash_including(:id, :action, :params))
      expect(command_queue).to receive(:wait_for_result).and_return({ success: true, result: { url: "https://example.com" } })
      
      server.send(:execute_browser_command, env, "navigate")
    end

    it "waits for command result" do
      allow(command_queue).to receive(:enqueue_command)
      expect(command_queue).to receive(:wait_for_result).with(anything, timeout: 30)
        .and_return({ success: true, result: { url: "https://example.com" } })
      
      server.send(:execute_browser_command, env, "navigate")
    end

    it "returns success response for successful command" do
      allow(command_queue).to receive(:enqueue_command)
      allow(command_queue).to receive(:wait_for_result)
        .and_return({ success: true, result: { url: "https://example.com" } })
      
      response = server.send(:execute_browser_command, env, "navigate")
      expect(response[0]).to eq(200)
    end

    it "returns error response for failed command" do
      allow(command_queue).to receive(:enqueue_command)
      allow(command_queue).to receive(:wait_for_result)
        .and_return({ success: false, error: "Navigation failed" })
      
      response = server.send(:execute_browser_command, env, "navigate")
      expect(response[0]).to eq(500)
    end

    it "handles JSON parsing errors" do
      env["rack.input"] = StringIO.new("invalid json")
      
      response = server.send(:execute_browser_command, env, "navigate")
      expect(response[0]).to eq(400)
      expect(JSON.parse(response[2][0])).to include("error" => "Invalid JSON")
    end

    it "handles command timeout" do
      allow(command_queue).to receive(:enqueue_command)
      allow(command_queue).to receive(:wait_for_result)
        .and_raise(VectorMCP::Browser::CommandQueue::TimeoutError)
      
      response = server.send(:execute_browser_command, env, "navigate")
      expect(response[0]).to eq(408)
      expect(JSON.parse(response[2][0])).to include("error" => "Command timed out")
    end

    it "logs command execution" do
      allow(command_queue).to receive(:enqueue_command)
      allow(command_queue).to receive(:wait_for_result)
        .and_return({ success: true, result: {} })
      
      expect(logger).to receive(:info).with("Browser command executed", context: hash_including(:command_id, :action, :user_id))
      expect(logger).to receive(:info).with("Browser command completed", context: hash_including(:success, :execution_time_ms))
      
      server.send(:execute_browser_command, env, "navigate")
    end
  end

  describe "extension endpoints" do
    describe "#handle_extension_ping" do
      let(:env) { { "REQUEST_METHOD" => "POST", "REMOTE_ADDR" => "127.0.0.1" } }

      it "requires POST method" do
        env["REQUEST_METHOD"] = "GET"
        response = server.send(:handle_extension_ping, env)
        expect(response[0]).to eq(405)
      end

      it "marks extension as connected" do
        server.send(:handle_extension_ping, env)
        expect(server.extension_connected?).to be(true)
      end

      it "updates last ping time" do
        freeze_time = Time.now
        allow(Time).to receive(:now).and_return(freeze_time)
        
        server.send(:handle_extension_ping, env)
        expect(server.instance_variable_get(:@extension_last_ping)).to eq(freeze_time)
      end

      it "returns success response" do
        response = server.send(:handle_extension_ping, env)
        expect(response[0]).to eq(200)
        expect(JSON.parse(response[2][0])).to include("status" => "ok")
      end

      it "logs connection event for new connections" do
        security_logger = instance_double("Logger")
        allow(VectorMCP).to receive(:logger_for).with("security.browser").and_return(security_logger)
        
        expect(security_logger).to receive(:info).with("Chrome extension connected", context: hash_including(:ip_address))
        
        server.send(:handle_extension_ping, env)
      end
    end

    describe "#handle_extension_poll" do
      let(:env) { { "REQUEST_METHOD" => "GET" } }
      let(:command_queue) { instance_double("CommandQueue") }

      before do
        allow(server).to receive(:command_queue).and_return(command_queue)
      end

      it "requires GET method" do
        env["REQUEST_METHOD"] = "POST"
        response = server.send(:handle_extension_poll, env)
        expect(response[0]).to eq(405)
      end

      it "returns pending commands" do
        commands = [{ id: "123", action: "navigate" }]
        expect(command_queue).to receive(:get_pending_commands).and_return(commands)
        
        response = server.send(:handle_extension_poll, env)
        expect(response[0]).to eq(200)
        expect(JSON.parse(response[2][0])).to include("commands" => commands)
      end
    end

    describe "#handle_extension_result" do
      let(:env) do
        {
          "REQUEST_METHOD" => "POST",
          "rack.input" => StringIO.new('{"command_id": "123", "success": true, "result": {"url": "https://example.com"}}')
        }
      end
      let(:command_queue) { instance_double("CommandQueue") }

      before do
        allow(server).to receive(:command_queue).and_return(command_queue)
      end

      it "requires POST method" do
        env["REQUEST_METHOD"] = "GET"
        response = server.send(:handle_extension_result, env)
        expect(response[0]).to eq(405)
      end

      it "completes command in queue" do
        expect(command_queue).to receive(:complete_command).with("123", true, {"url" => "https://example.com"}, nil)
        
        response = server.send(:handle_extension_result, env)
        expect(response[0]).to eq(200)
      end

      it "handles JSON parsing errors" do
        env["rack.input"] = StringIO.new("invalid json")
        
        response = server.send(:handle_extension_result, env)
        expect(response[0]).to eq(400)
      end
    end
  end

  describe "#handle_wait_command" do
    let(:env) do
      {
        "REQUEST_METHOD" => "POST",
        "rack.input" => StringIO.new('{"duration": 1000}')
      }
    end

    it "requires POST method" do
      env["REQUEST_METHOD"] = "GET"
      response = server.send(:handle_wait_command, env)
      expect(response[0]).to eq(405)
    end

    it "waits for specified duration" do
      start_time = Time.now
      response = server.send(:handle_wait_command, env)
      end_time = Time.now
      
      expect(response[0]).to eq(200)
      expect(end_time - start_time).to be >= 1.0
    end

    it "uses default duration when not specified" do
      env["rack.input"] = StringIO.new('{}')
      
      start_time = Time.now
      response = server.send(:handle_wait_command, env)
      end_time = Time.now
      
      expect(response[0]).to eq(200)
      expect(end_time - start_time).to be >= 1.0
    end

    it "handles JSON parsing errors" do
      env["rack.input"] = StringIO.new("invalid json")
      
      response = server.send(:handle_wait_command, env)
      expect(response[0]).to eq(400)
    end
  end

  describe "helper methods" do
    describe "#sanitize_params_for_logging" do
      it "redacts sensitive fields" do
        params = { "url" => "https://example.com", "password" => "secret123" }
        result = server.send(:sanitize_params_for_logging, params)
        
        expect(result["url"]).to eq("https://example.com")
        expect(result["password"]).to eq("[REDACTED]")
      end

      it "truncates long text values" do
        long_text = "A" * 1500
        params = { "text" => long_text }
        result = server.send(:sanitize_params_for_logging, params)
        
        expect(result["text"]).to include("[TRUNCATED]")
        expect(result["text"].length).to be < long_text.length
      end

      it "handles non-hash input" do
        result = server.send(:sanitize_params_for_logging, "string")
        expect(result).to eq("string")
      end
    end

    describe "#security_error_response" do
      it "returns 401 for authentication required" do
        security_result = { error_code: "AUTHENTICATION_REQUIRED", error: "Auth required" }
        response = server.send(:security_error_response, security_result)
        
        expect(response[0]).to eq(401)
        expect(JSON.parse(response[2][0])).to include("error" => "Auth required")
      end

      it "returns 403 for authorization failed" do
        security_result = { error_code: "AUTHORIZATION_FAILED", error: "Access denied" }
        response = server.send(:security_error_response, security_result)
        
        expect(response[0]).to eq(403)
        expect(JSON.parse(response[2][0])).to include("error" => "Access denied")
      end

      it "defaults to 401 for unknown error codes" do
        security_result = { error_code: "UNKNOWN", error: "Unknown error" }
        response = server.send(:security_error_response, security_result)
        
        expect(response[0]).to eq(401)
      end
    end
  end
end