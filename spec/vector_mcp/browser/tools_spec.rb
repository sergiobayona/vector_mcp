# frozen_string_literal: true

require "spec_helper"
require "vector_mcp/browser"

RSpec.describe VectorMCP::Browser::Tools do
  let(:logger) { Logger.new(StringIO.new) }
  let(:mock_operation_logger) do
    double("VectorMCP Logger").tap do |mock|
      allow(mock).to receive(:info)
      allow(mock).to receive(:warn)  
      allow(mock).to receive(:error)
      allow(mock).to receive(:debug)
    end
  end

  describe "Base class" do
    let(:base_tool) { VectorMCP::Browser::Tools::Base.new(logger: logger) }

    describe "#initialize" do
      it "sets default server host and port" do
        expect(base_tool.server_host).to eq("localhost")
        expect(base_tool.server_port).to eq(8000)
      end

      it "accepts custom server configuration" do
        tool = VectorMCP::Browser::Tools::Base.new(
          server_host: "example.com",
          server_port: 9000,
          logger: logger
        )
        
        expect(tool.server_host).to eq("example.com")
        expect(tool.server_port).to eq(9000)
      end

      it "sets up operation logger" do
        expect(base_tool.operation_logger).not_to be_nil
      end
    end

    describe "#sanitize_params_for_logging" do
      it "redacts sensitive fields" do
        params = {
          "url" => "https://example.com",
          "password" => "secret123",
          "token" => "abc123",
          "authorization" => "Bearer xyz"
        }
        
        result = base_tool.send(:sanitize_params_for_logging, params)
        
        expect(result["url"]).to eq("https://example.com")
        expect(result["password"]).to eq("[REDACTED]")
        expect(result["token"]).to eq("[REDACTED]")
        expect(result["authorization"]).to eq("[REDACTED]")
      end

      it "truncates long text values" do
        long_text = "A" * 1000
        params = { "text" => long_text }
        
        result = base_tool.send(:sanitize_params_for_logging, params)
        
        expect(result["text"]).to include("[TRUNCATED]")
        expect(result["text"].length).to be < long_text.length
      end

      it "handles non-hash input gracefully" do
        result = base_tool.send(:sanitize_params_for_logging, "string")
        expect(result).to eq("string")
      end

      it "preserves non-sensitive data" do
        params = {
          "url" => "https://example.com",
          "selector" => "button.primary",
          "coordinate" => [100, 200]
        }
        
        result = base_tool.send(:sanitize_params_for_logging, params)
        expect(result).to eq(params)
      end
    end

    describe "#make_browser_request" do
      let(:mock_http) { instance_double("Net::HTTP") }
      let(:mock_response) { instance_double("Net::HTTPResponse") }

      before do
        allow(Net::HTTP).to receive(:new).and_return(mock_http)
        allow(mock_http).to receive(:open_timeout=)
        allow(mock_http).to receive(:read_timeout=)
        allow(mock_http).to receive(:request).and_return(mock_response)
        allow(VectorMCP).to receive(:logger_for).with("browser.operations").and_return(mock_operation_logger)
      end

      context "with successful response" do
        before do
          allow(mock_response).to receive(:code).and_return("200")
          allow(mock_response).to receive(:body).and_return('{"success": true, "result": {"url": "https://example.com"}}')
          allow(mock_response).to receive(:length).and_return(50)
        end

        it "makes HTTP request to correct endpoint" do
          expect(Net::HTTP).to receive(:new).with("localhost", 8000)
          
          base_tool.send(:make_browser_request, "navigate", { url: "https://example.com" })
        end

        it "sets request headers and body" do
          request = instance_double("Net::HTTP::Post")
          expect(Net::HTTP::Post).to receive(:new).and_return(request)
          expect(request).to receive(:[]=).with("Content-Type", "application/json")
          expect(request).to receive(:body=).with('{"url":"https://example.com"}')
          
          base_tool.send(:make_browser_request, "navigate", { url: "https://example.com" })
        end

        it "returns parsed JSON response" do
          result = base_tool.send(:make_browser_request, "navigate", { url: "https://example.com" })
          
          expect(result).to eq({ "success" => true, "result" => { "url" => "https://example.com" } })
        end

        it "logs operation start and completion" do
          expect(mock_operation_logger).to receive(:info).with("Browser operation started", context: hash_including(:operation_id, :endpoint, :tool))
          expect(mock_operation_logger).to receive(:info).with("Browser operation completed", context: hash_including(:operation_id, :success, :execution_time_ms))
          
          base_tool.send(:make_browser_request, "navigate", { url: "https://example.com" })
        end
      end

      context "with extension not connected (503)" do
        before do
          allow(mock_response).to receive(:code).and_return("503")
          allow(mock_response).to receive(:body).and_return('{"error": "Extension not connected"}')
          allow(mock_response).to receive(:length).and_return(30)
        end

        it "raises ExtensionNotConnectedError" do
          expect {
            base_tool.send(:make_browser_request, "navigate", {})
          }.to raise_error(VectorMCP::Browser::ExtensionNotConnectedError, "Chrome extension not connected")
        end

        it "logs extension not connected warning" do
          expect(mock_operation_logger).to receive(:info).with("Browser operation started", anything)
          expect(mock_operation_logger).to receive(:warn).with("Browser operation failed - extension not connected", 
            context: hash_including(:error => "Extension not connected"))
          
          begin
            base_tool.send(:make_browser_request, "navigate", {})
          rescue VectorMCP::Browser::ExtensionNotConnectedError
            # Expected
          end
        end
      end

      context "with timeout (408)" do
        before do
          allow(mock_response).to receive(:code).and_return("408")
          allow(mock_response).to receive(:body).and_return('{"error": "Operation timed out"}')
          allow(mock_response).to receive(:length).and_return(25)
        end

        it "raises TimeoutError" do
          expect {
            base_tool.send(:make_browser_request, "navigate", {})
          }.to raise_error(VectorMCP::Browser::TimeoutError, "Browser operation timed out")
        end

        it "logs timeout warning" do
          expect(mock_operation_logger).to receive(:warn).with("Browser operation timed out", 
            context: hash_including(:error => "Operation timeout"))
          
          begin
            base_tool.send(:make_browser_request, "navigate", {})
          rescue VectorMCP::Browser::TimeoutError
            # Expected
          end
        end
      end

      context "with other HTTP errors" do
        before do
          allow(mock_response).to receive(:code).and_return("500")
          allow(mock_response).to receive(:body).and_return('{"error": "Internal server error"}')
          allow(mock_response).to receive(:length).and_return(30)
        end

        it "raises OperationError" do
          expect {
            base_tool.send(:make_browser_request, "navigate", {})
          }.to raise_error(VectorMCP::Browser::OperationError, "Internal server error")
        end

        it "logs operation failure" do
          expect(mock_operation_logger).to receive(:error).with("Browser operation failed", 
            context: hash_including(:error => "Internal server error", :status_code => 500))
          
          begin
            base_tool.send(:make_browser_request, "navigate", {})
          rescue VectorMCP::Browser::OperationError
            # Expected
          end
        end
      end

      context "with network timeouts" do
        before do
          allow(mock_http).to receive(:request).and_raise(Net::OpenTimeout)
        end

        it "raises TimeoutError for Net::OpenTimeout" do
          expect {
            base_tool.send(:make_browser_request, "navigate", {})
          }.to raise_error(VectorMCP::Browser::TimeoutError, "Request to browser server timed out")
        end

        it "logs network timeout error" do
          expect(mock_operation_logger).to receive(:error).with("Browser operation network timeout", 
            context: hash_including(:error_type => "Net::OpenTimeout"))
          
          begin
            base_tool.send(:make_browser_request, "navigate", {})
          rescue VectorMCP::Browser::TimeoutError
            # Expected
          end
        end
      end

      context "with connection refused" do
        before do
          allow(mock_http).to receive(:request).and_raise(Errno::ECONNREFUSED)
        end

        it "raises ExtensionNotConnectedError" do
          expect {
            base_tool.send(:make_browser_request, "navigate", {})
          }.to raise_error(VectorMCP::Browser::ExtensionNotConnectedError, "Cannot connect to browser server")
        end
      end
    end
  end

  describe "Navigate tool" do
    let(:navigate_tool) { VectorMCP::Browser::Tools::Navigate.new(logger: logger) }

    before do
      allow(VectorMCP).to receive(:logger_for).with("browser.operations").and_return(mock_operation_logger)
    end

    describe "#call" do
      let(:arguments) { { "url" => "https://example.com" } }
      let(:session_context) { double("SessionContext", user: { id: "user123" }) }

      it "requires url argument" do
        expect(navigate_tool).to receive(:make_browser_request)
          .with("navigate", { url: "https://example.com", include_snapshot: false })
          .and_return({ "success" => true, "result" => { "url" => "https://example.com" } })
        
        result = navigate_tool.call(arguments, session_context)
        expect(result[:url]).to eq("https://example.com")
      end

      it "supports include_snapshot option" do
        arguments["include_snapshot"] = true
        snapshot_data = "# ARIA Snapshot\n- role: button\n  name: \"Click me\""
        
        expect(navigate_tool).to receive(:make_browser_request)
          .with("navigate", { url: "https://example.com", include_snapshot: true })
          .and_return({ 
            "success" => true, 
            "result" => { 
              "url" => "https://example.com", 
              "snapshot" => snapshot_data 
            } 
          })
        
        result = navigate_tool.call(arguments, session_context)
        expect(result[:url]).to eq("https://example.com")
        expect(result[:snapshot]).to eq(snapshot_data)
      end

      it "logs navigation intent and completion" do
        expect(mock_operation_logger).to receive(:info).with("Browser navigation initiated", 
          context: hash_including(
            tool: "Navigate",
            url: "https://example.com",
            user_id: "user123"
          ))
        expect(mock_operation_logger).to receive(:info).with("Browser navigation completed",
          context: hash_including(
            tool: "Navigate",
            final_url: "https://example.com"
          ))
        
        allow(navigate_tool).to receive(:make_browser_request)
          .and_return({ "success" => true, "result" => { "url" => "https://example.com" } })
        
        navigate_tool.call(arguments, session_context)
      end

      it "raises OperationError on failure" do
        allow(navigate_tool).to receive(:make_browser_request)
          .and_return({ "success" => false, "error" => "Navigation failed" })
        
        expect(mock_operation_logger).to receive(:error).with("Browser navigation failed",
          context: hash_including(error: "Navigation failed"))
        
        expect {
          navigate_tool.call(arguments, session_context)
        }.to raise_error(VectorMCP::Browser::OperationError, "Navigation failed")
      end
    end
  end

  describe "Click tool" do
    let(:click_tool) { VectorMCP::Browser::Tools::Click.new(logger: logger) }

    before do
      allow(VectorMCP).to receive(:logger_for).with("browser.operations").and_return(mock_operation_logger)
    end

    describe "#call" do
      let(:session_context) { double("SessionContext", user: { id: "user123" }) }

      context "with selector" do
        let(:arguments) { { "selector" => "button.primary" } }

        it "clicks element by selector" do
          expect(click_tool).to receive(:make_browser_request)
            .with("click", {
              selector: "button.primary",
              coordinate: nil,
              include_snapshot: true
            })
            .and_return({ "success" => true, "result" => { "success" => true } })
          
          result = click_tool.call(arguments, session_context)
          expect(result[:success]).to be(true)
        end

        it "logs click intent and completion" do
          expect(mock_operation_logger).to receive(:info).with("Browser click initiated",
            context: hash_including(
              tool: "Click",
              selector: "button.primary",
              user_id: "user123"
            ))
          expect(mock_operation_logger).to receive(:info).with("Browser click completed",
            context: hash_including(tool: "Click"))
          
          allow(click_tool).to receive(:make_browser_request)
            .and_return({ "success" => true, "result" => { "success" => true } })
          
          click_tool.call(arguments, session_context)
        end
      end

      context "with coordinates" do
        let(:arguments) { { "coordinate" => [100, 200] } }

        it "clicks element by coordinates" do
          expect(click_tool).to receive(:make_browser_request)
            .with("click", {
              selector: nil,
              coordinate: [100, 200],
              include_snapshot: true
            })
            .and_return({ "success" => true, "result" => { "success" => true } })
          
          result = click_tool.call(arguments, session_context)
          expect(result[:success]).to be(true)
        end
      end

      context "with snapshot disabled" do
        let(:arguments) { { "selector" => "button", "include_snapshot" => false } }

        it "disables snapshot inclusion" do
          expect(click_tool).to receive(:make_browser_request)
            .with("click", hash_including(include_snapshot: false))
            .and_return({ "success" => true, "result" => { "success" => true } })
          
          click_tool.call(arguments, session_context)
        end
      end

      it "includes snapshot in response when available" do
        snapshot_data = "# Snapshot data"
        arguments = { "selector" => "button" }
        
        allow(click_tool).to receive(:make_browser_request)
          .and_return({ 
            "success" => true, 
            "result" => { 
              "success" => true, 
              "snapshot" => snapshot_data 
            } 
          })
        
        result = click_tool.call(arguments, session_context)
        expect(result[:snapshot]).to eq(snapshot_data)
      end

      it "raises OperationError on failure" do
        arguments = { "selector" => "button" }
        
        allow(click_tool).to receive(:make_browser_request)
          .and_return({ "success" => false, "error" => "Element not found" })
        
        expect(mock_operation_logger).to receive(:error).with("Browser click failed",
          context: hash_including(error: "Element not found"))
        
        expect {
          click_tool.call(arguments, session_context)
        }.to raise_error(VectorMCP::Browser::OperationError, "Element not found")
      end
    end
  end

  describe "Type tool" do
    let(:type_tool) { VectorMCP::Browser::Tools::Type.new(logger: logger) }

    before do
      allow(VectorMCP).to receive(:logger_for).with("browser.operations").and_return(mock_operation_logger)
    end

    describe "#call" do
      let(:arguments) { { "text" => "Hello World", "selector" => "input[type=text]" } }
      let(:session_context) { double("SessionContext", user: { id: "user123" }) }

      it "types text into element" do
        expect(type_tool).to receive(:make_browser_request)
          .with("type", {
            text: "Hello World",
            selector: "input[type=text]",
            coordinate: nil,
            include_snapshot: true
          })
          .and_return({ "success" => true, "result" => { "success" => true } })
        
        result = type_tool.call(arguments, session_context)
        expect(result[:success]).to be(true)
      end

      it "logs typing intent with text length (not content)" do
        expect(mock_operation_logger).to receive(:info).with("Browser typing initiated",
          context: hash_including(
            tool: "Type",
            text_length: 11, # "Hello World".length
            selector: "input[type=text]",
            user_id: "user123"
          ))
        expect(mock_operation_logger).to receive(:info).with("Browser typing completed",
          context: hash_including(text_length: 11))
        
        allow(type_tool).to receive(:make_browser_request)
          .and_return({ "success" => true, "result" => { "success" => true } })
        
        type_tool.call(arguments, session_context)
      end

      it "works with coordinates instead of selector" do
        arguments = { "text" => "Hello", "coordinate" => [100, 200] }
        
        expect(type_tool).to receive(:make_browser_request)
          .with("type", hash_including(
            text: "Hello",
            coordinate: [100, 200],
            selector: nil
          ))
          .and_return({ "success" => true, "result" => { "success" => true } })
        
        type_tool.call(arguments, session_context)
      end

      it "handles empty text gracefully" do
        arguments = { "text" => "", "selector" => "input" }
        
        expect(mock_operation_logger).to receive(:info).with("Browser typing initiated",
          context: hash_including(text_length: 0))
        
        allow(type_tool).to receive(:make_browser_request)
          .and_return({ "success" => true, "result" => { "success" => true } })
        
        type_tool.call(arguments, session_context)
      end

      it "raises OperationError on failure" do
        allow(type_tool).to receive(:make_browser_request)
          .and_return({ "success" => false, "error" => "Input field not found" })
        
        expect(mock_operation_logger).to receive(:error).with("Browser typing failed",
          context: hash_including(error: "Input field not found"))
        
        expect {
          type_tool.call(arguments, session_context)
        }.to raise_error(VectorMCP::Browser::OperationError, "Input field not found")
      end
    end
  end

  describe "Snapshot tool" do
    let(:snapshot_tool) { VectorMCP::Browser::Tools::Snapshot.new(logger: logger) }

    describe "#call" do
      let(:arguments) { {} }
      let(:session_context) { nil }

      it "captures page snapshot" do
        snapshot_data = "# ARIA Snapshot\n- role: button\n  name: \"Click me\""
        
        expect(snapshot_tool).to receive(:make_browser_request)
          .with("snapshot", {})
          .and_return({ "success" => true, "result" => { "snapshot" => snapshot_data } })
        
        result = snapshot_tool.call(arguments, session_context)
        expect(result[:snapshot]).to eq(snapshot_data)
      end

      it "raises OperationError on failure" do
        expect(snapshot_tool).to receive(:make_browser_request)
          .and_return({ "success" => false, "error" => "Failed to capture snapshot" })
        
        expect {
          snapshot_tool.call(arguments, session_context)
        }.to raise_error(VectorMCP::Browser::OperationError, "Failed to capture snapshot")
      end
    end
  end

  describe "Screenshot tool" do
    let(:screenshot_tool) { VectorMCP::Browser::Tools::Screenshot.new(logger: logger) }

    describe "#call" do
      let(:arguments) { {} }
      let(:session_context) { nil }

      it "captures screenshot" do
        screenshot_data = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg=="
        
        expect(screenshot_tool).to receive(:make_browser_request)
          .with("screenshot", {})
          .and_return({ "success" => true, "result" => { "screenshot" => screenshot_data } })
        
        result = screenshot_tool.call(arguments, session_context)
        expect(result[:type]).to eq("image")
        expect(result[:data]).to eq("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==")
        expect(result[:mimeType]).to eq("image/png")
      end

      it "raises OperationError on failure" do
        expect(screenshot_tool).to receive(:make_browser_request)
          .and_return({ "success" => false, "error" => "Failed to capture screenshot" })
        
        expect {
          screenshot_tool.call(arguments, session_context)
        }.to raise_error(VectorMCP::Browser::OperationError, "Failed to capture screenshot")
      end
    end
  end

  describe "Console tool" do
    let(:console_tool) { VectorMCP::Browser::Tools::Console.new(logger: logger) }

    describe "#call" do
      let(:arguments) { {} }
      let(:session_context) { nil }

      it "retrieves console logs" do
        logs = ["Error: Something went wrong", "Warning: Deprecated API"]
        
        expect(console_tool).to receive(:make_browser_request)
          .with("console", {})
          .and_return({ "success" => true, "result" => { "logs" => logs } })
        
        result = console_tool.call(arguments, session_context)
        expect(result[:logs]).to eq(logs)
      end
    end
  end

  describe "Wait tool" do
    let(:wait_tool) { VectorMCP::Browser::Tools::Wait.new(logger: logger) }

    describe "#call" do
      it "waits for default duration" do
        arguments = {}
        
        expect(wait_tool).to receive(:make_browser_request)
          .with("wait", { duration: 1000 })
          .and_return({ "success" => true, "result" => "Waited 1000ms" })
        
        result = wait_tool.call(arguments, nil)
        expect(result).to eq({ message: "Waited 1000ms" })
      end

      it "waits for specified duration" do
        arguments = { "duration" => 2500 }
        
        expect(wait_tool).to receive(:make_browser_request)
          .with("wait", { duration: 2500 })
          .and_return({ "success" => true, "result" => "Waited 2500ms" })
        
        result = wait_tool.call(arguments, nil)
        expect(result).to eq({ message: "Waited 2500ms" })
      end
    end
  end
end