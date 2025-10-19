# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "json"
require "uri"
require "timeout"
require "socket"
require "vector_mcp/transport/http_stream"

RSpec.describe "Async HTTP Client Integration", type: :integration do
  # Use standard Net::HTTP for this test to avoid timing issues
  # The async functionality is already tested in the existing HTTP Stream integration tests

  # Find an available port for testing
  def find_available_port
    server = TCPServer.new("localhost", 0)
    port = server.addr[1]
    server.close
    port
  end

  let(:test_port) { find_available_port }
  let(:base_url) { "http://localhost:#{test_port}" }
  let(:mcp_endpoint) { "#{base_url}/mcp" }

  # Create a test server directly
  let(:server) do
    VectorMCP.new(
      name: "Async Test Server",
      version: "1.0.0",
      log_level: Logger::ERROR # Reduce noise during tests
    )
  end

  let(:transport) { VectorMCP::Transport::HttpStream.new(server, port: test_port, host: "localhost") }

  before(:each) do
    # Register test tools
    server.register_tool(
      name: "echo",
      description: "Echo test tool",
      input_schema: {
        type: "object",
        properties: { message: { type: "string" } },
        required: ["message"]
      }
    ) { |args| "Echo: #{args["message"]}" }

    server.register_tool(
      name: "math_add",
      description: "Add two numbers",
      input_schema: {
        type: "object",
        properties: {
          a: { type: "number" },
          b: { type: "number" }
        },
        required: %w[a b]
      }
    ) { |args| args["a"] + args["b"] }

    # Start the server in a background thread
    @server_thread = Thread.new do
      transport.run
    rescue StandardError
      # Server stopped, this is expected during cleanup
    end

    # Wait for server to start
    wait_for_server_start
  end

  after(:each) do
    # Stop the server
    transport.stop
    @server_thread&.join(2) # Wait up to 2 seconds for graceful shutdown
    @server_thread&.kill if @server_thread&.alive? # Force kill if still alive
    @server_thread = nil
  end

  # Helper method to wait for server to start
  def wait_for_server_start
    Timeout.timeout(10) do
      loop do
        Net::HTTP.get_response(URI("#{base_url}/"))
        break
      rescue Errno::ECONNREFUSED
        sleep(0.1)
      end
    end
  rescue Timeout::Error
    raise "Server failed to start within 10 seconds"
  end

  # Helper method to make HTTP requests with session ID
  def make_request(method, path, body: nil, headers: {}, session_id: nil)
    uri = URI("#{base_url}#{path}")
    http = Net::HTTP.new(uri.host, uri.port)

    request = case method.upcase
              when "GET"
                Net::HTTP::Get.new(uri)
              when "POST"
                Net::HTTP::Post.new(uri)
              when "DELETE"
                Net::HTTP::Delete.new(uri)
              else
                raise "Unsupported HTTP method: #{method}"
              end

    headers.each { |k, v| request[k] = v }
    request["Mcp-Session-Id"] = session_id if session_id
    request["Content-Type"] = "application/json" if body
    request.body = body.to_json if body

    http.request(request)
  end

  # Helper method to parse JSON-RPC response
  def parse_json_rpc_response(response)
    JSON.parse(response.body)
  end

  # Helper method to create JSON-RPC request
  def create_json_rpc_request(method, params = nil, id: 1)
    request = { jsonrpc: "2.0", method: method, id: id }
    request[:params] = params if params
    request
  end

  describe "Async HTTP Backend Integration" do
    it "successfully processes requests through the async-enabled HTTP transport" do
      session_id = "async-integration-test"

      # Initialize session
      init_request = create_json_rpc_request("initialize", {
                                               protocolVersion: "2024-11-05",
                                               capabilities: {},
                                               clientInfo: { name: "async-test-client", version: "1.0.0" }
                                             })

      response = make_request("POST", "/mcp", body: init_request, session_id: session_id)
      expect(response.code).to eq("200")

      # Test basic tool call - this exercises the async HTTP transport internally
      call_request = create_json_rpc_request("tools/call", {
                                               name: "echo",
                                               arguments: { message: "Async transport test" }
                                             })

      response = make_request("POST", "/mcp", body: call_request, session_id: session_id)
      expect(response.code).to eq("200")

      data = parse_json_rpc_response(response)
      expect(data["result"]["content"]).to be_an(Array)
      expect(data["result"]["content"].first["text"]).to eq("Echo: Async transport test")
    end

    it "handles concurrent requests efficiently" do
      session_count = 3
      threads = []
      results = Concurrent::Array.new

      session_count.times do |i|
        threads << Thread.new do
          session_id = "concurrent-async-session-#{i}"

          # Initialize session
          init_request = create_json_rpc_request("initialize", {
                                                   protocolVersion: "2024-11-05",
                                                   capabilities: {},
                                                   clientInfo: { name: "test-client-#{i}", version: "1.0.0" }
                                                 })

          response = make_request("POST", "/mcp", body: init_request, session_id: session_id)
          expect(response.code).to eq("200")

          # Make a tool call
          call_request = create_json_rpc_request("tools/call", {
                                                   name: "math_add",
                                                   arguments: { a: i * 10, b: 5 }
                                                 })

          response = make_request("POST", "/mcp", body: call_request, session_id: session_id)
          expect(response.code).to eq("200")

          data = parse_json_rpc_response(response)
          result = data["result"]["content"].first["text"]
          results << { session: i, result: result.to_i }
        end
      end

      # Wait for all threads to complete
      threads.each(&:join)

      # Verify all results are correct
      expect(results.size).to eq(session_count)
      results.each do |item|
        expected = item[:session] * 10 + 5
        expect(item[:result]).to eq(expected)
      end
    end

    it "maintains session isolation in concurrent environment" do
      session1_id = "isolation-test-1"
      session2_id = "isolation-test-2"

      # Initialize both sessions
      [session1_id, session2_id].each do |session_id|
        init_request = create_json_rpc_request("initialize", {
                                                 protocolVersion: "2024-11-05",
                                                 capabilities: {},
                                                 clientInfo: { name: "isolation-client", version: "1.0.0" }
                                               })

        response = make_request("POST", "/mcp", body: init_request, session_id: session_id)
        expect(response.code).to eq("200")
      end

      # Make concurrent calls with different arguments
      threads = []
      results = {}

      [
        [session1_id, "Session 1 message"],
        [session2_id, "Session 2 message"]
      ].each do |session_id, message|
        threads << Thread.new do
          call_request = create_json_rpc_request("tools/call", {
                                                   name: "echo",
                                                   arguments: { message: message }
                                                 })

          response = make_request("POST", "/mcp", body: call_request, session_id: session_id)
          data = parse_json_rpc_response(response)
          results[session_id] = data["result"]["content"].first["text"]
        end
      end

      # Wait for completion
      threads.each(&:join)

      # Verify session isolation
      expect(results[session1_id]).to eq("Echo: Session 1 message")
      expect(results[session2_id]).to eq("Echo: Session 2 message")
    end
  end
end