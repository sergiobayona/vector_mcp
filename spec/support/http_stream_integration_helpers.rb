# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "timeout"
require "socket"

module HttpStreamIntegrationHelpers
  # Find an available port for testing
  def find_available_port
    server = TCPServer.new("localhost", 0)
    port = server.addr[1]
    server.close
    port
  end

  # Helper method to wait for server to start
  def wait_for_server_start(base_url, timeout: 10)
    Timeout.timeout(timeout) do
      loop do
        begin
          Net::HTTP.get_response(URI("#{base_url}/"))
          break
        rescue Errno::ECONNREFUSED
          sleep(0.1)
        end
      end
    end
  rescue Timeout::Error
    raise "Server failed to start within #{timeout} seconds"
  end

  # Helper method to make HTTP requests with session ID
  def make_http_request(method, base_url, path, body: nil, headers: {}, session_id: nil)
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

  # Helper method to initialize an MCP session
  def initialize_mcp_session(base_url, session_id, client_info: nil)
    client_info ||= { name: "test-client", version: "1.0.0" }
    
    init_request = create_json_rpc_request("initialize", {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: client_info
    })
    
    response = make_http_request("POST", base_url, "/mcp", body: init_request, session_id: session_id)
    expect(response.code).to eq("200")
    
    data = parse_json_rpc_response(response)
    # HttpStream transport returns raw results, not JSON-RPC wrapped
    if data["result"]
      expect(data["result"]).not_to be_nil
    else
      # For HttpStream, we expect raw response data
      expect(data).not_to be_nil
    end
    
    response
  end

  # Helper method to establish streaming connection
  def establish_streaming_connection(base_url, session_id, headers: {})
    default_headers = {
      "Accept" => "text/event-stream",
      "Cache-Control" => "no-cache"
    }
    
    make_http_request("GET", base_url, "/mcp", 
                      headers: default_headers.merge(headers), 
                      session_id: session_id)
  end

  # Helper method to call a tool
  def call_tool(base_url, session_id, tool_name, arguments = {})
    request = create_json_rpc_request("tools/call", {
      name: tool_name,
      arguments: arguments
    })
    
    response = make_http_request("POST", base_url, "/mcp", body: request, session_id: session_id)
    expect(response.code).to eq("200")
    
    parse_json_rpc_response(response)
  end

  # Helper method to list tools
  def list_tools(base_url, session_id)
    request = create_json_rpc_request("tools/list", {})
    response = make_http_request("POST", base_url, "/mcp", body: request, session_id: session_id)
    expect(response.code).to eq("200")
    
    parse_json_rpc_response(response)
  end

  # Helper method to read a resource
  def read_resource(base_url, session_id, uri)
    request = create_json_rpc_request("resources/read", { uri: uri })
    response = make_http_request("POST", base_url, "/mcp", body: request, session_id: session_id)
    expect(response.code).to eq("200")
    
    parse_json_rpc_response(response)
  end

  # Helper method to get a prompt
  def get_prompt(base_url, session_id, name, arguments = {})
    request = create_json_rpc_request("prompts/get", {
      name: name,
      arguments: arguments
    })
    
    response = make_http_request("POST", base_url, "/mcp", body: request, session_id: session_id)
    expect(response.code).to eq("200")
    
    parse_json_rpc_response(response)
  end

  # Helper method to terminate session
  def terminate_session(base_url, session_id)
    response = make_http_request("DELETE", base_url, "/mcp", session_id: session_id)
    expect(response.code).to eq("200")
    response
  end

  # Test server setup helper
  def create_test_server(name: "Test Server", version: "1.0.0", log_level: Logger::ERROR)
    server = VectorMCP.new(
      name: name,
      version: version,
      log_level: log_level
    )

    # Register standard test tools
    register_test_tools(server)
    register_test_resources(server)
    register_test_prompts(server)

    server
  end

  # Register standard test tools
  def register_test_tools(server)
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
        required: ["a", "b"]
      }
    ) { |args| args["a"] + args["b"] }

    server.register_tool(
      name: "error_tool",
      description: "Tool that always throws an error",
      input_schema: {
        type: "object",
        properties: {},
        required: []
      }
    ) { |args| raise StandardError, "Test error" }
  end

  # Register standard test resources
  def register_test_resources(server)
    server.register_resource(
      name: "test_resource",
      description: "Test resource",
      uri: "test://resource"
    ) { { content: "test resource content" } }

    server.register_resource(
      name: "json_resource",
      description: "JSON test resource",
      uri: "test://json"
    ) { { data: { key: "value", number: 42 } } }
  end

  # Register standard test prompts
  def register_test_prompts(server)
    server.register_prompt(
      name: "test_prompt",
      description: "Test prompt",
      arguments: [
        {
          name: "context",
          description: "Context for the prompt",
          required: true
        }
      ]
    ) { |args| "Test prompt with context: #{args["context"]}" }

    server.register_prompt(
      name: "simple_prompt",
      description: "Simple prompt with no arguments",
      arguments: []
    ) { |args| "Simple prompt response" }
  end

  # Server lifecycle management
  def start_test_server(server, port, host: "localhost")
    transport = VectorMCP::Transport::HttpStream.new(server, port: port, host: host)
    
    server_thread = Thread.new do
      transport.run
    rescue StandardError
      # Server stopped, this is expected during cleanup
    end

    # Wait for server to start
    wait_for_server_start("http://#{host}:#{port}")
    
    [transport, server_thread]
  end

  def stop_test_server(transport, server_thread)
    transport.stop
    server_thread&.join(2) # Wait up to 2 seconds for graceful shutdown
    server_thread&.kill if server_thread&.alive? # Force kill if still alive
  end

  # Concurrent testing helper
  def run_concurrent_sessions(base_url, session_count: 3, &block)
    sessions = []
    threads = []
    
    session_count.times do |i|
      session_id = "concurrent-session-#{i}"
      sessions << session_id
      
      threads << Thread.new do
        initialize_mcp_session(base_url, session_id, client_info: { 
          name: "test-client-#{i}", 
          version: "1.0.0" 
        })
        
        yield(session_id, i) if block_given?
      end
    end
    
    # Wait for all threads to complete
    threads.each(&:join)
    
    sessions
  end

  # Streaming client mock for testing sampling
  class MockStreamingClient
    def initialize(session_id, base_url)
      @session_id = session_id
      @base_url = base_url
      @responses = {}
      @running = false
      @stream_thread = nil
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
          parse_sse_events(chunk) do |message|
            if message["method"] == "sampling/createMessage"
              handle_sampling_request(message)
            end
          end
        end
      end
    rescue StandardError
      # Stream ended or error occurred
    end

    def parse_sse_events(chunk)
      chunk.split("\n\n").each do |event_data|
        next if event_data.strip.empty?
        
        event_lines = event_data.split("\n")
        data = nil
        
        event_lines.each do |line|
          data = line[6..-1] if line.start_with?("data: ")
        end
        
        if data
          begin
            message = JSON.parse(data)
            yield message
          rescue JSON::ParserError
            # Ignore malformed JSON
          end
        end
      end
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
end