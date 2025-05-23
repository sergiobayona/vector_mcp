# frozen_string_literal: true

require "spec_helper"
require "open3"
require "json"
require "timeout"

RSpec.describe "VectorMCP Server (Stdio Integration)" do
  # Path to the example server script to run
  # Adjust if your example script is located elsewhere or named differently
  let(:server_script) { File.expand_path("../../examples/stdio_server.rb", __dir__) }

  # Variables to hold process pipes and thread
  let(:stdin) { @server_stdin }
  let(:stdout) { @server_stdout }
  let(:stderr) { @server_stderr }
  let(:wait_thr) { @server_wait_thr }
  let(:server_pid) { @server_pid }

  # Request ID counter
  let(:req_id) do
    @request_id ||= 0
    @request_id += 1
  end

  # Helper to send JSON-RPC message (as hash) to server's stdin
  def send_jsonrpc(message_hash)
    json_message = message_hash.to_json
    VectorMCP.logger.debug "[TEST->] #{json_message}"
    begin
      stdin.puts(json_message)
      stdin.flush
    rescue Errno::EPIPE
      # Server process likely exited unexpectedly
      raise "Failed to write to server stdin (EPIPE). Server process might have crashed."
    end
  end

  # Helper to read a single JSON-RPC message (as hash) from server's stdout
  # rubocop:disable Metrics/MethodLength
  def read_jsonrpc(timeout_seconds = 2)
    raw_line = nil
    begin
      Timeout.timeout(timeout_seconds) do
        # Read lines until a non-empty one is found or EOF
        loop do
          raw_line = stdout.gets
          break raw_line if raw_line && !raw_line.strip.empty?
          # If gets returns nil, it means EOF
          raise EOFError, "Server stdout closed unexpectedly." if raw_line.nil?
        end
      end
      VectorMCP.logger.debug "[<-TEST] #{raw_line.strip}"
      JSON.parse(raw_line)
    rescue Timeout::Error
      raise Timeout::Error, "Timeout waiting for response from server after #{timeout_seconds}s. Last read line: #{raw_line.inspect}"
    rescue JSON::ParserError => e
      raise JSON::ParserError, "Failed to parse JSON from server: '#{raw_line.strip}'. Error: #{e.message}"
    rescue EOFError => e
      # Log stderr from server process to help diagnose crashes
      begin
        server_stderr = stderr.read unless stderr.closed?
        VectorMCP.logger.error "Server stderr dump on EOFError:\n#{server_stderr}" if server_stderr && !server_stderr.empty?
      rescue IOError
        # Ignore IOError when trying to read from closed stderr
      end
      raise e # Re-raise the EOFError
    end
  end
  # rubocop:enable Metrics/MethodLength
  # --- Test Setup & Teardown ---

  before(:each) do
    # Start the server process for each test
    # Use popen3 to get stdin, stdout, stderr, and wait thread
    @server_stdin, @server_stdout, @server_stderr, @server_wait_thr = Open3.popen3("ruby", server_script)
    @server_pid = @server_wait_thr.pid
    @request_id = 0 # Reset request ID counter for each test
    VectorMCP.logger.info "Started server process (PID: #{@server_pid}) for test."

    # Optional: Small sleep to allow server to fully initialize (usually not needed for stdio)
    # sleep 0.1
  end

  after(:each) do
    VectorMCP.logger.info "Stopping server process (PID: #{server_pid})."
    begin
      # Close stdin first to signal EOF to server
      stdin.close if stdin && !stdin.closed?

      # Send TERM signal
      Process.kill("TERM", server_pid)

      # Wait for process to exit, with timeout
      begin
        Timeout.timeout(3) do
          wait_thr.join
        end
        VectorMCP.logger.info "Server process (PID: #{server_pid}) terminated cleanly."
      rescue Timeout::Error
        VectorMCP.logger.warn "Server process (PID: #{server_pid}) did not exit after TERM, sending KILL."
        Process.kill("KILL", server_pid)
        wait_thr.join # Wait again after KILL
      end
    rescue Errno::ESRCH
      # Process already exited, which is fine
      VectorMCP.logger.info "Server process (PID: #{server_pid}) already exited."
    rescue StandardError => e
      VectorMCP.logger.error "Error during server process cleanup: #{e.class}: #{e.message}"
    ensure
      # Ensure pipes are closed even if errors occurred
      stdout.close if stdout && !stdout.closed?
      stderr.close if stderr && !stderr.closed?
    end

    # Log any remaining stderr output for debugging failed tests
    begin
      server_stderr_output = stderr.read unless stderr.closed?
      unless server_stderr_output.nil? || server_stderr_output.empty?
        VectorMCP.logger.warn "Server stderr output during test:\n---\n#{server_stderr_output}\n---"
      end
    rescue IOError
      # Ignore IOError when trying to read from closed stderr
    end
  end

  # --- Test Cases ---

  context "Initialization Handshake" do
    it "completes the initialize/initialized flow" do
      # 1. Send initialize request
      init_request = {
        jsonrpc: "2.0",
        id: req_id,
        method: "initialize",
        params: {
          protocolVersion: VectorMCP::Server::PROTOCOL_VERSION,
          capabilities: {}, # Client capabilities (empty for test)
          clientInfo: { name: "RSpecClient", version: "1.0" }
        }
      }
      send_jsonrpc(init_request)

      # 2. Expect initialize result
      init_response = read_jsonrpc
      expect(init_response["id"]).to eq(init_request[:id])
      expect(init_response["result"]).to eq({
                                              "protocolVersion" => "2024-11-05",
                                              "capabilities" => {
                                                "tools" => { "listChanged" => false },
                                                "resources" => { "subscribe" => false, "listChanged" => false },
                                                "prompts" => { "listChanged" => true },
                                                "sampling" => {
                                                  "methods" => ["createMessage"],
                                                  "features" => {
                                                    "modelPreferences" => true
                                                  },
                                                  "limits" => {
                                                    "defaultTimeout" => 30
                                                  },
                                                  "contextInclusion" => %w[none thisServer]
                                                }
                                              },
                                              "serverInfo" => { "name" => "VectorMCP::ExampleServer", "version" => "0.0.1" }
                                            })

      # 3. Send initialized notification
      initialized_notification = {
        jsonrpc: "2.0",
        method: "initialized",
        params: {}
      }
      send_jsonrpc(initialized_notification)
      # No response expected for notification, just ensure no crash
    end
  end

  context "Core Methods" do
    before do
      # Perform handshake before each test in this context
      send_jsonrpc({ jsonrpc: "2.0", id: req_id, method: "initialize",
                     params: { protocolVersion: VectorMCP::Server::PROTOCOL_VERSION, capabilities: {}, clientInfo: {} } })
      read_jsonrpc # Consume initialize result
      send_jsonrpc({ jsonrpc: "2.0", method: "initialized", params: {} })
    end

    it "responds to ping" do
      ping_request = { jsonrpc: "2.0", id: req_id, method: "ping", params: {} }
      send_jsonrpc(ping_request)
      response = read_jsonrpc
      expect(response["id"]).to eq(ping_request[:id])
      expect(response["result"]).to eq({}) # Empty object signifies success
    end
  end

  context "Tools" do
    before do
      # Perform handshake
      send_jsonrpc({ jsonrpc: "2.0", id: req_id, method: "initialize",
                     params: { protocolVersion: VectorMCP::Server::PROTOCOL_VERSION, capabilities: {}, clientInfo: {} } })
      read_jsonrpc
      send_jsonrpc({ jsonrpc: "2.0", method: "initialized", params: {} })
    end

    it "lists the registered 'ruby_echo' tool" do
      list_req = { jsonrpc: "2.0", id: req_id, method: "tools/list", params: {} }
      send_jsonrpc(list_req)
      response = read_jsonrpc
      expect(response["id"]).to eq(list_req[:id])
      expect(response["result"]["tools"]).to be_an(Array)
      expect(response["result"]["tools"].size).to eq(1)
      expect(response["result"]["tools"][0]).to include(
        "name" => "ruby_echo",
        "description" => "Echoes the input string.",
        "inputSchema" => hash_including("type" => "object")
      )
    end

    it "calls the 'ruby_echo' tool successfully" do
      call_req = {
        jsonrpc: "2.0",
        id: req_id,
        method: "tools/call",
        params: {
          name: "ruby_echo",
          arguments: { message: "Integration Test!" }
        }
      }
      send_jsonrpc(call_req)
      response = read_jsonrpc
      expect(response["id"]).to eq(call_req[:id])
      expect(response["result"]["isError"]).to be false
      expect(response["result"]["content"]).to eq([
                                                    { "type" => "text", "text" => "You said via VectorMCP: Integration Test!",
                                                      "mimeType" => "text/plain" }
                                                  ])
    end

    it "returns an error when calling a non-existent tool" do
      call_req = {
        jsonrpc: "2.0",
        id: req_id,
        method: "tools/call",
        params: { name: "non_existent_tool" }
      }
      send_jsonrpc(call_req)
      response = read_jsonrpc
      VectorMCP.logger.debug "Error response: #{response.inspect}"
      expect(response["id"]).to eq(call_req[:id])
      expect(response).to include("error")
      expect(response["error"]["code"]).to eq(-32_001) # VectorMCP::NotFoundError code
      expect(response["error"]["message"]).to eq("Not Found")
      expect(response["error"]["data"]).to include("Tool not found: non_existent_tool")
    end
  end

  context "Resources" do
    before do
      # Perform handshake
      send_jsonrpc({ jsonrpc: "2.0", id: req_id, method: "initialize",
                     params: { protocolVersion: VectorMCP::Server::PROTOCOL_VERSION, capabilities: {}, clientInfo: {} } })
      read_jsonrpc
      send_jsonrpc({ jsonrpc: "2.0", method: "initialized", params: {} })
    end

    it "lists the registered memory resource" do
      list_req = { jsonrpc: "2.0", id: req_id, method: "resources/list", params: {} }
      send_jsonrpc(list_req)
      response = read_jsonrpc
      expect(response["id"]).to eq(list_req[:id])
      expect(response["result"]["resources"]).to be_an(Array)
      expect(response["result"]["resources"].size).to eq(1)
      expect(response["result"]["resources"][0]).to include(
        "uri" => "memory://data/example.txt",
        "name" => "Example Data",
        "description" => "Some simple data stored in server memory.",
        "mimeType" => "text/plain"
      )
    end

    it "reads the memory resource successfully" do
      read_req = {
        jsonrpc: "2.0",
        id: req_id,
        method: "resources/read",
        params: { uri: "memory://data/example.txt" }
      }
      send_jsonrpc(read_req)
      response = read_jsonrpc
      expect(response["id"]).to eq(read_req[:id])
      expect(response["result"]["contents"]).to be_an(Array)
      expect(response["result"]["contents"].size).to eq(1)
      expect(response["result"]["contents"][0]).to include(
        "uri" => "memory://data/example.txt",
        "type" => "text",
        "mimeType" => "text/plain"
      )
      expect(response["result"]["contents"][0]["text"]).to start_with("This is the content of the example resource.")
    end

    it "returns an error when reading a non-existent resource" do
      read_req = {
        jsonrpc: "2.0",
        id: req_id,
        method: "resources/read",
        params: { uri: "memory://does/not/exist" }
      }
      send_jsonrpc(read_req)
      response = read_jsonrpc
      expect(response["id"]).to eq(read_req[:id])
      expect(response).to include("error")
      expect(response["error"]["code"]).to eq(-32_001) # VectorMCP::NotFoundError code
      expect(response["error"]["message"]).to eq("Not Found")
      expect(response["error"]["data"]).to include("Resource not found: memory://does/not/exist")
    end
  end

  context "Prompts" do
    before do
      # Perform handshake
      send_jsonrpc({ jsonrpc: "2.0", id: req_id, method: "initialize",
                     params: { protocolVersion: VectorMCP::Server::PROTOCOL_VERSION, capabilities: {}, clientInfo: {} } })
      read_jsonrpc
      send_jsonrpc({ jsonrpc: "2.0", method: "initialized", params: {} })
    end

    it "lists the registered 'simple_greeting' prompt" do
      list_req = { jsonrpc: "2.0", id: req_id, method: "prompts/list", params: {} }
      send_jsonrpc(list_req)
      response = read_jsonrpc
      expect(response["id"]).to eq(list_req[:id])
      expect(response["result"]["prompts"]).to be_an(Array)
      expect(response["result"]["prompts"].size).to eq(1)
      expect(response["result"]["prompts"][0]).to include(
        "name" => "simple_greeting",
        "description" => "Generates a simple greeting.",
        "arguments" => array_including(hash_including("name" => "name", "required" => true))
      )
    end

    it "gets the 'simple_greeting' prompt successfully" do
      get_req = {
        jsonrpc: "2.0",
        id: req_id,
        method: "prompts/get",
        params: {
          name: "simple_greeting",
          arguments: { name: "RSpec" }
        }
      }
      send_jsonrpc(get_req)
      response = read_jsonrpc
      expect(response["id"]).to eq(get_req[:id])
      expect(response["result"]["description"]).to eq("Greeting prepared for RSpec.")
      expect(response["result"]["messages"]).to eq([
                                                     { "role" => "user",
                                                       "content" => { "type" => "text", "text" => "Greet RSpec using VectorMCP style." } },
                                                     { "role" => "assistant",
                                                       "content" => { "type" => "text", "text" => "Alright, crafting a greeting for RSpec now." } }
                                                   ])
    end

    it "returns an error when getting a non-existent prompt" do
      get_req = {
        jsonrpc: "2.0",
        id: req_id,
        method: "prompts/get",
        params: { name: "non_existent_prompt" }
      }
      send_jsonrpc(get_req)
      response = read_jsonrpc
      expect(response["id"]).to eq(get_req[:id])
      expect(response).to include("error")
      expect(response["error"]["code"]).to eq(-32_001) # VectorMCP::NotFoundError code
      expect(response["error"]["message"]).to eq("Not Found")
      expect(response["error"]["data"]).to include("Prompt not found: non_existent_prompt")
    end
  end

  context "Malformed Requests" do
    # No handshake needed for these tests

    it "returns a parse error for invalid JSON" do
      # Send raw invalid JSON string
      invalid_json_string = '{"jsonrpc": "2.0", "id": 1, "method": "test'
      VectorMCP.logger.debug "[TEST->] #{invalid_json_string}"
      stdin.puts(invalid_json_string)
      stdin.flush

      response = read_jsonrpc
      expect(response["id"]).to eq("1") # Corrected expectation to string "1"
      expect(response).to include("error")
      expect(response["error"]["code"]).to eq(-32_700)
      expect(response["error"]["message"]).to eq("Parse error")
    end

    it "returns invalid request for missing method" do
      # Send invalid request
      req = { jsonrpc: "2.0", id: req_id, params: {} }
      send_jsonrpc(req)
      response = read_jsonrpc
      expect(response["id"]).to eq(req[:id])
      expect(response).to include("error")
      expect(response["error"]["code"]).to eq(-32_600)
      expect(response["error"]["message"]).to eq("Request object must include a 'method' member.")
    end
  end
end
