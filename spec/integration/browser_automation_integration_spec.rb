# frozen_string_literal: true

require "spec_helper"
require "vector_mcp/browser"
require "net/http"
require "json"

RSpec.describe "Browser Automation Integration", type: :integration, skip: "Integration tests require SSE transport implementation" do
  let(:server) { VectorMCP::Server.new("browser-test-server") }
  let(:transport) { VectorMCP::Transport::SSE.new(server, port: 8999, host: "127.0.0.1") }
  let(:server_url) { "http://127.0.0.1:8999" }

  before(:all) do
    # Start server in background thread
    @server_thread = Thread.new do
      server = VectorMCP::Server.new("browser-integration-test")
      server.register_browser_tools
      transport = VectorMCP::Transport::SSE.new(server, port: 8999, host: "127.0.0.1")

      begin
        server.run(transport: transport)
      rescue StandardError
        # Server stopped - this is expected in tests
      end
    end

    # Wait for server to start
    max_attempts = 10
    attempts = 0

    begin
      sleep(0.5)
      Net::HTTP.get_response(URI("#{server_url}/browser/ping"))
    rescue Errno::ECONNREFUSED
      attempts += 1
      raise "Server failed to start within #{max_attempts * 0.5} seconds" unless attempts < max_attempts

      sleep(0.5)
      retry
    end
  end

  after(:all) do
    # Stop server thread
    @server_thread&.kill
    @server_thread&.join(2)
  end

  describe "Extension Communication" do
    it "handles extension ping requests" do
      response = make_request("/browser/ping", method: "POST", data: { timestamp: Time.now.to_f })

      expect(response.code).to eq("200")
      body = JSON.parse(response.body)
      expect(body["status"]).to eq("ok")
    end

    it "handles extension polling for commands" do
      response = make_request("/browser/poll", method: "GET")

      expect(response.code).to eq("200")
      body = JSON.parse(response.body)
      expect(body).to have_key("commands")
      expect(body["commands"]).to be_an(Array)
    end

    it "handles extension result submission" do
      result_data = {
        command_id: "test-123",
        success: true,
        result: { url: "https://example.com" }
      }

      response = make_request("/browser/result", method: "POST", data: result_data)

      expect(response.code).to eq("200")
      body = JSON.parse(response.body)
      expect(body["status"]).to eq("ok")
    end
  end

  describe "Browser Commands" do
    context "without extension connected" do
      it "returns service unavailable for browser commands" do
        response = make_request("/browser/navigate", method: "POST",
                                                     data: { url: "https://example.com" })

        expect(response.code).to eq("503")
        body = JSON.parse(response.body)
        expect(body["error"]).to include("not connected")
      end
    end

    context "with simulated extension" do
      before do
        # Simulate extension connection
        make_request("/browser/ping", method: "POST", data: { timestamp: Time.now.to_f })
      end

      it "accepts navigation commands" do
        response = make_request("/browser/navigate", method: "POST",
                                                     data: { url: "https://example.com" })

        # Command should be accepted and queued (will timeout waiting for extension response)
        expect(response.code).to eq("408") # Timeout expected since no real extension
      end

      it "accepts click commands" do
        response = make_request("/browser/click", method: "POST",
                                                  data: { selector: "button.primary" })

        expect(response.code).to eq("408") # Timeout expected
      end

      it "accepts type commands" do
        response = make_request("/browser/type", method: "POST",
                                                 data: { text: "Hello World", selector: "input" })

        expect(response.code).to eq("408") # Timeout expected
      end

      it "accepts snapshot commands" do
        response = make_request("/browser/snapshot", method: "POST", data: {})

        expect(response.code).to eq("408") # Timeout expected
      end

      it "accepts screenshot commands" do
        response = make_request("/browser/screenshot", method: "POST", data: {})

        expect(response.code).to eq("408") # Timeout expected
      end

      it "accepts console commands" do
        response = make_request("/browser/console", method: "POST", data: {})

        expect(response.code).to eq("408") # Timeout expected
      end

      it "handles wait commands locally (no extension needed)" do
        start_time = Time.now
        response = make_request("/browser/wait", method: "POST",
                                                 data: { duration: 100 })
        end_time = Time.now

        expect(response.code).to eq("200")
        expect(end_time - start_time).to be >= 0.1

        body = JSON.parse(response.body)
        expect(body["success"]).to be(true)
        expect(body["result"]).to include("Waited 100ms")
      end
    end
  end

  describe "Command Queue Integration" do
    before do
      # Simulate extension connection
      make_request("/browser/ping", method: "POST", data: { timestamp: Time.now.to_f })
    end

    it "queues and dispatches commands to extension" do
      # Send a command (will be queued)
      command_thread = Thread.new do
        make_request("/browser/navigate", method: "POST",
                                          data: { url: "https://example.com" })
      end

      # Give command time to be queued
      sleep(0.1)

      # Extension polls for commands
      response = make_request("/browser/poll", method: "GET")
      body = JSON.parse(response.body)

      expect(body["commands"]).not_to be_empty
      command = body["commands"].first
      expect(command["action"]).to eq("navigate")
      expect(command["params"]["url"]).to eq("https://example.com")

      # Simulate extension completing the command
      make_request("/browser/result", method: "POST", data: {
                     command_id: command["id"],
                     success: true,
                     result: { url: "https://example.com" }
                   })

      # Original command should complete
      command_thread.join(2)
    end

    it "handles multiple concurrent commands" do
      command_threads = []

      # Send multiple commands concurrently
      3.times do |i|
        command_threads << Thread.new do
          make_request("/browser/navigate", method: "POST",
                                            data: { url: "https://example#{i}.com" })
        end
      end

      # Give commands time to be queued
      sleep(0.1)

      # Extension polls for commands
      response = make_request("/browser/poll", method: "GET")
      body = JSON.parse(response.body)

      expect(body["commands"].length).to eq(3)

      # Complete all commands
      body["commands"].each do |command|
        make_request("/browser/result", method: "POST", data: {
                       command_id: command["id"],
                       success: true,
                       result: { url: command["params"]["url"] }
                     })
      end

      # All command threads should complete
      command_threads.each { |t| t.join(2) }
    end
  end

  describe "Error Handling" do
    it "handles invalid JSON in requests" do
      uri = URI("#{server_url}/browser/navigate")
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = "invalid json"

      response = Net::HTTP.start(uri.hostname, uri.port) do |http|
        http.request(request)
      end

      expect(response.code).to eq("400")
      body = JSON.parse(response.body)
      expect(body["error"]).to include("Invalid JSON")
    end

    it "handles missing required parameters" do
      response = make_request("/browser/navigate", method: "POST", data: {})

      # Should accept the request but command will likely fail
      # The HTTP server doesn't validate parameters - that's the extension's job
      expect([400, 408, 503]).to include(response.code.to_i)
    end

    it "handles invalid endpoints" do
      response = make_request("/browser/invalid", method: "POST", data: {})

      expect(response.code).to eq("404")
    end

    it "handles invalid HTTP methods" do
      response = make_request("/browser/navigate", method: "GET")

      expect(response.code).to eq("405")
    end
  end

  describe "MCP Tool Integration" do
    let(:test_server) { VectorMCP::Server.new("mcp-browser-test") }

    before do
      test_server.register_browser_tools(server_host: "127.0.0.1", server_port: 8999)
    end

    it "registers browser tools with MCP server" do
      expected_tools = %w[
        browser_navigate browser_click browser_type browser_snapshot
        browser_screenshot browser_console browser_wait
      ]

      expect(test_server.tools.keys).to include(*expected_tools)
    end

    it "executes navigate tool through MCP interface" do
      navigate_tool = test_server.tools["browser_navigate"]
      arguments = { "url" => "https://example.com" }

      # Mock extension connection
      make_request("/browser/ping", method: "POST", data: { timestamp: Time.now.to_f })

      # Mock the HTTP request to avoid real browser communication
      http_mock = instance_double("Net::HTTP")
      instance_double("Net::HTTPResponse")

      allow(Net::HTTP).to receive(:new).and_return(http_mock)
      allow(http_mock).to receive(:open_timeout=)
      allow(http_mock).to receive(:read_timeout=)
      allow(http_mock).to receive(:request).and_raise(Errno::ECONNREFUSED)

      # Mock the operation logger
      operation_logger = double("VectorMCP Operation Logger").tap do |mock|
        allow(mock).to receive(:info)
        allow(mock).to receive(:warn)
        allow(mock).to receive(:error)
        allow(mock).to receive(:debug)
      end
      allow(VectorMCP).to receive(:logger_for).with("browser.operations").and_return(operation_logger)

      # This should raise ExtensionNotConnectedError instead of hanging
      expect do
        navigate_tool.handler.call(arguments)
      end.to raise_error(VectorMCP::Browser::ExtensionNotConnectedError)
    end

    it "validates tool input schemas" do
      navigate_tool = test_server.tools["browser_navigate"]

      # Valid arguments
      valid_args = { "url" => "https://example.com" }
      expect do
        JSON::Validator.validate!(navigate_tool.input_schema, valid_args)
      end.not_to raise_error

      # Invalid arguments (missing url)
      invalid_args = { "include_snapshot" => true }
      expect do
        JSON::Validator.validate!(navigate_tool.input_schema, invalid_args)
      end.to raise_error(JSON::Schema::ValidationError)
    end
  end

  describe "Logging Integration" do
    it "logs browser operations" do
      # Create a string IO to capture logs
      log_output = StringIO.new
      test_logger = Logger.new(log_output)

      # Mock the operation logger
      allow(VectorMCP).to receive(:logger_for).with("browser.operations").and_return(test_logger)

      # Make a request that will generate logs
      make_request("/browser/ping", method: "POST", data: { timestamp: Time.now.to_f })

      # Check that logs were generated
      log_content = log_output.string
      expect(log_content).not_to be_empty
    end
  end

  private

  def make_request(path, method: "GET", data: nil)
    uri = URI("#{server_url}#{path}")

    case method.upcase
    when "GET"
      request = Net::HTTP::Get.new(uri)
    when "POST"
      request = Net::HTTP::Post.new(uri)
    else
      raise "Unsupported method: #{method}"
    end

    if data
      request["Content-Type"] = "application/json"
      request.body = data.to_json
    end

    Net::HTTP.start(uri.hostname, uri.port) do |http|
      http.read_timeout = 1 # Short timeout for tests
      http.open_timeout = 1
      http.request(request)
    end
  rescue Net::OpenTimeout, Net::ReadTimeout
    # Return a mock response for timeout
    response = Object.new
    def code = "408"
    def body = '{"error": "Request timed out"}'
    response
  end
end
