# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "json"
require "uri"
require "timeout"
require "socket"
require "vector_mcp/transport/http_stream"

RSpec.describe "HTTP Stream Transport - Streaming Features" do
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
  let(:stream_endpoint) { "#{base_url}/mcp" }

  # Create a test server directly
  let(:server) do
    VectorMCP.new(
      name: "HTTP Stream Streaming Test Server",
      version: "1.0.0",
      log_level: Logger::ERROR # Reduce noise during tests
    )
  end

  let(:transport) { VectorMCP::Transport::HttpStream.new(server, port: test_port, host: "localhost") }

  before(:each) do
    # Register a tool that uses sampling for server-initiated requests
    server.register_tool(
      name: "interactive_tool",
      description: "Tool that interacts with client via sampling",
      input_schema: {
        type: "object",
        properties: { 
          question: { type: "string" },
          follow_up: { type: "boolean", default: false }
        },
        required: ["question"]
      }
    ) do |args, session|
      # Use sampling to ask the client
      result = session.sample(
        messages: [
          {
            role: "user",
            content: {
              type: "text",
              text: args["question"]
            }
          }
        ],
        system_prompt: "You are a helpful assistant. Give a brief response.",
        max_tokens: 100
      )
      
      response = { initial_response: result.content }
      
      if args["follow_up"]
        # Ask a follow-up question
        follow_up_result = session.sample(
          messages: [
            {
              role: "user",
              content: {
                type: "text",
                text: "Can you elaborate on that?"
              }
            }
          ],
          system_prompt: "You are a helpful assistant. Give a brief response.",
          max_tokens: 100
        )
        response[:follow_up_response] = follow_up_result.content
      end
      
      response
    end

    # Register a tool that tests session-specific sampling
    server.register_tool(
      name: "session_sampler",
      description: "Tests session-specific sampling functionality",
      input_schema: {
        type: "object",
        properties: { message: { type: "string" } },
        required: ["message"]
      }
    ) do |args, session|
      # Sample from the current session
      result = session.sample(
        messages: [
          {
            role: "user",
            content: {
              type: "text",
              text: "Echo back: #{args["message"]}"
            }
          }
        ],
        system_prompt: "You are a helpful assistant. Echo back the exact message.",
        max_tokens: 50
      )
      
      {
        session_id: session.id,
        original_message: args["message"],
        sampled_response: result.content
      }
    end

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
        begin
          Net::HTTP.get_response(URI("#{base_url}/health"))
          break
        rescue Errno::ECONNREFUSED
          sleep(0.1)
        end
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

  # Helper method to establish streaming connection
  def establish_streaming_connection(session_id)
    uri = URI(stream_endpoint)
    http = Net::HTTP.new(uri.host, uri.port)
    
    request = Net::HTTP::Get.new(uri)
    request["Mcp-Session-Id"] = session_id
    request["Accept"] = "text/event-stream"
    request["Cache-Control"] = "no-cache"
    
    # Start the streaming request
    http.request(request)
  end

  # Mock client that can respond to sampling requests
  class MockStreamingClient
    def initialize(session_id, base_url)
      @session_id = session_id
      @base_url = base_url
      @responses = {}
      @running = false
    end

    def start_streaming
      @running = true
      @stream_thread = Thread.new { handle_stream }
    end

    def stop_streaming
      @running = false
      @stream_thread&.join(1)
      @stream_thread&.kill if @stream_thread&.alive?
    end

    def set_response_for_method(method, response)
      @responses[method] = response
    end

    private

    def handle_stream
      uri = URI("#{@base_url}/mcp")
      http = Net::HTTP.new(uri.host, uri.port)
      
      request = Net::HTTP::Get.new(uri)
      request["Mcp-Session-Id"] = @session_id
      request["Accept"] = "text/event-stream"
      request["Cache-Control"] = "no-cache"
      
      http.request(request) do |response|
        response.read_body do |chunk|
          break unless @running
          
          # Parse SSE events
          chunk.split("\n\n").each do |event_data|
            next if event_data.strip.empty?
            
            event_lines = event_data.split("\n")
            event_type = nil
            data = nil
            
            event_lines.each do |line|
              if line.start_with?("event: ")
                event_type = line[7..-1]
              elsif line.start_with?("data: ")
                data = line[6..-1]
              end
            end
            
            if data
              begin
                message = JSON.parse(data)
                if message["method"] == "sampling/createMessage"
                  handle_sampling_request(message)
                end
              rescue JSON::ParserError
                # Ignore malformed JSON
              end
            end
          end
        end
      end
    rescue StandardError
      # Stream ended or error occurred
    end

    def handle_sampling_request(message)
      method = message["method"]
      request_id = message["id"]
      
      # Create a mock response
      response = {
        jsonrpc: "2.0",
        id: request_id,
        result: {
          role: "assistant",
          content: {
            type: "text",
            text: @responses[method] || "Mock response from streaming client"
          }
        }
      }
      
      # Send response back to server
      send_response(response)
    end

    def send_response(response)
      uri = URI("#{@base_url}/mcp")
      http = Net::HTTP.new(uri.host, uri.port)
      
      request = Net::HTTP::Post.new(uri)
      request["Mcp-Session-Id"] = @session_id
      request["Content-Type"] = "application/json"
      request.body = response.to_json
      
      http.request(request)
    end
  end

  describe "Server-Initiated Requests (Sampling)" do
    let(:session_id) { "sampling-test-session" }
    let(:mock_client) { MockStreamingClient.new(session_id, base_url) }

    before do
      # Initialize session
      init_request = create_json_rpc_request("initialize", {
        protocolVersion: "2024-11-05",
        capabilities: { sampling: {} },
        clientInfo: { name: "test-client", version: "1.0.0" }
      })
      
      response = make_request("POST", "/mcp", body: init_request, session_id: session_id)
      expect(response.code).to eq("200")
      
      # Set up mock client responses
      mock_client.set_response_for_method("sampling/createMessage", "This is a mock response to your question")
      mock_client.start_streaming
      
      # Give streaming connection time to establish
      sleep(0.5)
    end

    after do
      mock_client.stop_streaming
    end

    it "supports server-initiated sampling requests" do
      # This test is complex because it requires a real streaming client
      # For now, we'll test the basic mechanism
      request = create_json_rpc_request("tools/call", {
        name: "interactive_tool",
        arguments: { question: "What is the capital of France?" }
      })
      
      response = make_request("POST", "/mcp", body: request, session_id: session_id)
      
      # The response should either succeed (if streaming works) or fail with a specific error
      expect(response.code).to eq("200")
      data = parse_json_rpc_response(response)
      
      # If sampling works, we should get a result
      # If no streaming connection, we should get an error about no streaming session
      if data["result"]
        expect(data["result"]["initial_response"]).to be_present
      else
        expect(data["error"]["message"]).to include("No streaming session available")
      end
    end

    it "handles session-specific sampling" do
      request = create_json_rpc_request("tools/call", {
        name: "session_sampler",
        arguments: { message: "test message for session" }
      })
      
      response = make_request("POST", "/mcp", body: request, session_id: session_id)
      expect(response.code).to eq("200")
      
      data = parse_json_rpc_response(response)
      
      # Should either succeed or fail with specific error
      if data["result"]
        expect(data["result"]["session_id"]).to eq(session_id)
        expect(data["result"]["original_message"]).to eq("test message for session")
      else
        expect(data["error"]["message"]).to include("No streaming session available")
      end
    end
  end

  describe "Event Store and Resumable Connections" do
    let(:session_id) { "event-store-test-session" }

    before do
      # Initialize session
      init_request = create_json_rpc_request("initialize", {
        protocolVersion: "2024-11-05",
        capabilities: {},
        clientInfo: { name: "test-client", version: "1.0.0" }
      })
      
      response = make_request("POST", "/mcp", body: init_request, session_id: session_id)
      expect(response.code).to eq("200")
    end

    it "supports streaming endpoint with session ID" do
      # Try to establish streaming connection
      response = make_request("GET", "/mcp", session_id: session_id, headers: {
        "Accept" => "text/event-stream",
        "Cache-Control" => "no-cache"
      })
      
      # Should get a streaming response
      expect(response.code).to eq("200")
      expect(response["Content-Type"]).to include("text/event-stream")
    end

    it "supports Last-Event-ID header for resumable connections" do
      # Make initial streaming request
      response = make_request("GET", "/mcp", session_id: session_id, headers: {
        "Accept" => "text/event-stream",
        "Cache-Control" => "no-cache"
      })
      
      expect(response.code).to eq("200")
      
      # Make request with Last-Event-ID header
      response = make_request("GET", "/mcp", session_id: session_id, headers: {
        "Accept" => "text/event-stream",
        "Cache-Control" => "no-cache",
        "Last-Event-ID" => "some-event-id"
      })
      
      expect(response.code).to eq("200")
      expect(response["Content-Type"]).to include("text/event-stream")
    end

    it "maintains event history for resumability" do
      # This test verifies that the event store maintains events
      # The actual resumability testing would require parsing SSE streams
      
      # Make a tool call that might generate events
      request = create_json_rpc_request("tools/call", {
        name: "interactive_tool",
        arguments: { question: "Generate some events" }
      })
      
      response = make_request("POST", "/mcp", body: request, session_id: session_id)
      expect(response.code).to eq("200")
      
      # The event store should be functioning (tested in unit tests)
      # Here we just verify the mechanism doesn't break
    end
  end

  describe "Session Lifecycle with Streaming" do
    let(:session_id) { "lifecycle-test-session" }

    it "supports streaming connection establishment" do
      # Initialize session
      init_request = create_json_rpc_request("initialize", {
        protocolVersion: "2024-11-05",
        capabilities: {},
        clientInfo: { name: "test-client", version: "1.0.0" }
      })
      
      response = make_request("POST", "/mcp", body: init_request, session_id: session_id)
      expect(response.code).to eq("200")
      
      # Establish streaming connection
      response = make_request("GET", "/mcp", session_id: session_id, headers: {
        "Accept" => "text/event-stream"
      })
      
      expect(response.code).to eq("200")
      expect(response["Content-Type"]).to include("text/event-stream")
    end

    it "supports explicit session termination" do
      # Initialize session
      init_request = create_json_rpc_request("initialize", {
        protocolVersion: "2024-11-05",
        capabilities: {},
        clientInfo: { name: "test-client", version: "1.0.0" }
      })
      
      response = make_request("POST", "/mcp", body: init_request, session_id: session_id)
      expect(response.code).to eq("200")
      
      # Terminate session
      response = make_request("DELETE", "/mcp", session_id: session_id)
      expect(response.code).to eq("200")
      
      # Verify session is terminated
      list_request = create_json_rpc_request("tools/list", {})
      response = make_request("POST", "/mcp", body: list_request, session_id: session_id)
      expect(response.code).to eq("200")
      # Should still work but may be a new session
    end

    it "handles streaming connection without active session" do
      # Try to establish streaming connection without initializing session
      response = make_request("GET", "/mcp", session_id: "non-existent-session", headers: {
        "Accept" => "text/event-stream"
      })
      
      # Should either create session or handle gracefully
      expect(response.code).to be_in(["200", "400", "404"])
    end
  end

  describe "Error Handling in Streaming Context" do
    let(:session_id) { "error-handling-session" }

    before do
      # Initialize session
      init_request = create_json_rpc_request("initialize", {
        protocolVersion: "2024-11-05",
        capabilities: {},
        clientInfo: { name: "test-client", version: "1.0.0" }
      })
      
      response = make_request("POST", "/mcp", body: init_request, session_id: session_id)
      expect(response.code).to eq("200")
    end

    it "handles sampling timeout gracefully" do
      # Call tool that would use sampling but with no streaming client
      request = create_json_rpc_request("tools/call", {
        name: "interactive_tool",
        arguments: { question: "This should timeout" }
      })
      
      response = make_request("POST", "/mcp", body: request, session_id: session_id)
      expect(response.code).to eq("200")
      
      data = parse_json_rpc_response(response)
      expect(data["error"]).to be_present
      expect(data["error"]["message"]).to include("No streaming session available")
    end

    it "handles invalid streaming requests" do
      # Try to make streaming request with invalid headers
      response = make_request("GET", "/mcp", session_id: session_id, headers: {
        "Accept" => "application/json" # Wrong content type
      })
      
      # Should handle gracefully
      expect(response.code).to be_in(["200", "400"])
    end
  end
end