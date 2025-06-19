# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "json"
require "uri"
require "timeout"
require "socket"
require "vector_mcp/transport/sse"

RSpec.describe "SSE Transport Basic Integration" do
  # Find an available port for testing
  def find_available_port
    server = TCPServer.new("localhost", 0)
    port = server.addr[1]
    server.close
    port
  end

  let(:test_port) { find_available_port }
  let(:base_url) { "http://localhost:#{test_port}" }

  # Create a test server directly
  let(:server) do
    VectorMCP.new(
      name: "SSE Integration Test Server",
      version: "1.0.0",
      log_level: Logger::ERROR # Reduce noise during tests
    )
  end

  let(:transport) { VectorMCP::Transport::SSE.new(server, port: test_port, host: "localhost") }

  before(:each) do
    # Register a simple test tool
    server.register_tool(
      name: "echo",
      description: "Echo test tool",
      input_schema: {
        type: "object",
        properties: { message: { type: "string" } },
        required: ["message"]
      }
    ) { |args| "Echo: #{args["message"]}" }

    # Start the server in a background thread
    @server_thread = Thread.new do
      transport.run
    rescue StandardError
      # Server stopped, this is expected during cleanup
    end

    # Wait for server to be ready
    wait_for_server_ready
  end

  after(:each) do
    transport&.stop
    @server_thread&.kill
    @server_thread&.join(2)
  end

  describe "Server Health and Connectivity" do
    it "responds to health check at root path" do
      response = Net::HTTP.get_response(URI("#{base_url}/"))
      expect(response.code).to eq("200")
      expect(response.body).to eq("VectorMCP Server OK")
    end

    it "serves SSE endpoint with proper headers" do
      uri = URI("#{base_url}/mcp/sse")
      http = Net::HTTP.new(uri.host, uri.port)
      http.read_timeout = 2

      request = Net::HTTP::Get.new(uri)
      http.request(request) do |response|
        expect(response.code).to eq("200")
        expect(response["content-type"]).to include("text/event-stream")
        expect(response["cache-control"]).to eq("no-cache")
        break # Don't read body, just check headers
      end
    end

    it "rejects POST requests to SSE endpoint" do
      uri = URI("#{base_url}/mcp/sse")
      response = Net::HTTP.post(uri, "{}")
      expect(response.code).to eq("405")
      expect(response["allow"]).to eq("GET")
    end

    it "returns 404 for unknown paths" do
      response = Net::HTTP.get_response(URI("#{base_url}/unknown"))
      expect(response.code).to eq("404")
      expect(response.body).to eq("Not Found")
    end
  end

  describe "SSE Connection Establishment" do
    it "establishes SSE connection and receives endpoint event" do
      session_id, message_url = establish_sse_connection

      expect(session_id).to match(/\A[0-9a-f-]{36}\z/) # UUID format
      expect(message_url).to start_with("#{base_url}/mcp/message?session_id=")
      expect(message_url).to include(session_id)
    end

    it "provides unique session IDs for different connections" do
      session_id1, = establish_sse_connection
      session_id2, = establish_sse_connection

      expect(session_id1).not_to eq(session_id2)
      expect(session_id1).to match(/\A[0-9a-f-]{36}\z/)
      expect(session_id2).to match(/\A[0-9a-f-]{36}\z/)
    end
  end

  describe "Message Endpoint Validation" do
    let(:session_id) { establish_sse_connection[0] }

    it "rejects requests without session_id" do
      uri = URI("#{base_url}/mcp/message")
      response = Net::HTTP.post(uri, { jsonrpc: "2.0", id: 1, method: "ping" }.to_json,
                                { "Content-Type" => "application/json" })
      expect(response.code).to eq("400")

      error_data = JSON.parse(response.body)
      expect(error_data["error"]["message"]).to eq("Missing session_id parameter")
    end

    it "rejects requests with invalid session_id" do
      uri = URI("#{base_url}/mcp/message?session_id=invalid")
      response = Net::HTTP.post(uri, { jsonrpc: "2.0", id: 1, method: "ping" }.to_json,
                                { "Content-Type" => "application/json" })
      expect(response.code).to eq("404")

      error_data = JSON.parse(response.body)
      expect(error_data["error"]["message"]).to eq("Invalid session_id")
    end

    it "accepts valid POST requests to message endpoint" do
      uri = URI("#{base_url}/mcp/message?session_id=#{session_id}")
      # Send initialize request first (required by MCP protocol)
      init_message = {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: {
          protocolVersion: "2024-11-05",
          capabilities: {},
          clientInfo: { name: "Test", version: "1.0" }
        }
      }
      response = Net::HTTP.post(uri, init_message.to_json, { "Content-Type" => "application/json" })
      expect(response.code).to eq("202") # Accepted
    end

    it "rejects non-POST requests to message endpoint" do
      uri = URI("#{base_url}/mcp/message?session_id=#{session_id}")
      response = Net::HTTP.get_response(uri)
      expect(response.code).to eq("405")
      expect(response["allow"]).to eq("POST")
    end
  end

  describe "JSON-RPC Message Handling" do
    it "handles malformed JSON appropriately" do
      session_id, = establish_sse_connection

      uri = URI("#{base_url}/mcp/message?session_id=#{session_id}")
      response = Net::HTTP.post(uri, '{"invalid": json}', { "Content-Type" => "application/json" })

      # Server should accept the POST but the response will be sent via SSE
      # For malformed JSON, the server returns 400 directly
      expect(response.code).to eq("400")

      error_data = JSON.parse(response.body)
      expect(error_data["error"]["code"]).to eq(-32_700) # Parse error
      expect(error_data["error"]["message"]).to eq("Parse error")
    end
  end

  describe "Concurrent Connections" do
    it "handles multiple simultaneous SSE connections" do
      connections = []

      # Establish 3 concurrent connections
      3.times do |i|
        session_id, message_url = establish_sse_connection
        connections << { id: i, session_id: session_id, message_url: message_url }
      end

      # Verify all connections have unique session IDs
      session_ids = connections.map { |c| c[:session_id] }
      expect(session_ids.uniq.size).to eq(3)

      # Verify all session IDs are valid UUIDs
      session_ids.each do |sid|
        expect(sid).to match(/\A[0-9a-f-]{36}\z/)
      end

      # Initialize the shared MCP session once (the transport uses a single session)
      first_conn = connections.first
      uri = URI(first_conn[:message_url])
      init_message = {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: {
          protocolVersion: "2024-11-05",
          capabilities: {},
          clientInfo: { name: "Test", version: "1.0" }
        }
      }
      response = Net::HTTP.post(uri, init_message.to_json, { "Content-Type" => "application/json" })
      expect(response.code).to eq("202")

      # Test that other connections can send messages (after session is initialized)
      connections[1..].each do |conn|
        uri = URI(conn[:message_url])
        ping_message = { jsonrpc: "2.0", id: 2, method: "ping", params: {} }
        response = Net::HTTP.post(uri, ping_message.to_json, { "Content-Type" => "application/json" })
        expect(response.code).to eq("202")
      end
    end
  end

  describe "Transport Lifecycle" do
    it "stops gracefully" do
      # Server should be running
      response = Net::HTTP.get_response(URI("#{base_url}/"))
      expect(response.code).to eq("200")

      # Stop the transport
      transport.stop

      # Wait a moment for cleanup
      sleep 0.5

      # Server should no longer respond
      expect do
        Net::HTTP.get_response(URI("#{base_url}/"))
      end.to raise_error(Errno::ECONNREFUSED)
    end
  end

  private

  def wait_for_server_ready
    Timeout.timeout(10) do
      loop do
        response = Net::HTTP.get_response(URI("#{base_url}/"))
        break if response.code == "200"
      rescue Errno::ECONNREFUSED, Net::ReadTimeout
        sleep 0.1
      end
    end
  rescue Timeout::Error
    raise "Test server failed to start within 10 seconds"
  end

  def establish_sse_connection
    session_id = nil
    message_url = nil

    uri = URI("#{base_url}/mcp/sse")
    http = Net::HTTP.new(uri.host, uri.port)
    http.read_timeout = 5

    request = Net::HTTP::Get.new(uri)
    http.request(request) do |response|
      raise "SSE connection failed: #{response.code}" unless response.code == "200"

      response.read_body do |chunk|
        chunk.each_line do |line|
          line = line.strip
          next if line.empty?

          next unless line.start_with?("data: /mcp/message?session_id=")

          path = line.sub("data: ", "")
          message_url = "#{base_url}#{path}"
          session_id = path[/session_id=([^&]+)/, 1]
          return [session_id, message_url]
        end
      end
    end

    raise "Failed to receive endpoint event"
  end
end
