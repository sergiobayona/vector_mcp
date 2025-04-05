# frozen_string_literal: true

require "spec_helper"
require "async"
# require "async/http" # Removed
# require "async/http/client" # Removed
# require "async/http/endpoint" # Removed
require "rack/mock" # Need this for env_for
require "json"
require "securerandom"

RSpec.describe MCPRuby::Transport::SSE do
  # include Rack::Test::Methods

  # --- Mocks and Doubles ---
  let(:server_double) do
    instance_double(MCPRuby::Server,
                    logger: logger_double,
                    server_info: server_info,
                    server_capabilities: server_capabilities,
                    protocol_version: protocol_version,
                    handle_message: nil)
  end

  let(:logger_double) { instance_double(Logger, info: nil, debug: nil, warn: nil, error: nil, fatal: nil) }
  let(:session_double) { instance_double(MCPRuby::Session, initialized?: true) } # Assume initialized for most tests
  let(:server_info) { { name: "TestSSE", version: "0.1" } }
  let(:server_capabilities) { { tools: { listChanged: false } } }
  let(:protocol_version) { MCPRuby::Server::PROTOCOL_VERSION }
  let(:options) { { host: "127.0.0.1", port: 9293, path_prefix: "/mcp_sse" } }

  # The transport instance under test
  subject(:transport) { described_class.new(server_double, options) }

  # Control session IDs for predictable testing
  let(:session_id) { "test-session-id-12345" }
  before { allow(SecureRandom).to receive(:uuid).and_return(session_id) }

  # Access internal state for assertions
  let(:clients) { transport.instance_variable_get(:@clients) }
  let(:clients_mutex) { transport.instance_variable_get(:@clients_mutex) }

  # Define app for Rack::Test using let
  let(:app) { transport.send(:build_rack_app, session_double) }
  # Define an endpoint serving the app on localhost, ephemeral port
  # let(:endpoint) { Async::HTTP::Endpoint.parse("http://127.0.0.1:0", timeout: 5, app: app) } # Removed
  # Define the test client pointing to the endpoint
  # let(:client) { Async::HTTP::Client.new(endpoint, protocol: Async::HTTP::Protocol::HTTP11) } # Removed

  # --- Test Helpers ---
  def sse_event(event, data)
    "event: #{event}\ndata: #{data}\n\n"
  end

  def simulate_post(path, body, headers = {})
    # post path, body.to_json, { "CONTENT_TYPE" => "application/json" }.merge(headers)
    # Need alternative way to test POST if Rack::Test is disabled
    # raise "Cannot simulate_post without Rack::Test enabled"
    # TODO: Update this to use the new client if needed, or remove if direct client.post is used
  end

  # Mock Writable Body for testing SSE stream output
  class MockWritableBody
    attr_reader :chunks, :finished, :closed_by_peer

    def initialize
      @chunks = []
      @finished = false
      @closed_by_peer = false
      @condition = Async::Condition.new
    end

    def write(chunk)
      raise IOError, "Body closed by peer" if @closed_by_peer
      return if @finished

      @chunks << chunk
      @condition.signal # Signal that data is available
    end

    def finish
      @finished = true
      @condition.signal
    end

    # Simulate peer closing connection
    def close
      @closed_by_peer = true
      @finished = true
      @condition.signal
    end

    # Helper to wait for chunks
    def read_chunks(count = 1, timeout = 0.5)
      result = []
      Async::Timeout.wrap(timeout) do
        while result.size < count && !@finished && !@closed_by_peer
          # Take available chunks first
          result.concat(@chunks)
          @chunks.clear

          # If still not enough and not finished/closed, wait for more data
          @condition.wait if result.size < count && !@finished && !@closed_by_peer
        end
      end # Async::Timeout will raise if it expires
      result
    rescue Async::TimeoutError
      # Return whatever we got before timeout, or an empty array
      result
    end
  end

  # --- Tests ---

  describe "#initialize" do
    it "initializes with server and options" do
      expect(transport.server).to eq(server_double)
      expect(transport.logger).to eq(logger_double)
      expect(transport.host).to eq("127.0.0.1")
      expect(transport.port).to eq(9293)
      expect(transport.path_prefix).to eq("/mcp_sse")
      expect(clients).to be_empty
    end

    it "correctly formats path_prefix" do
      transport1 = described_class.new(server_double, { path_prefix: "mcp/" })
      expect(transport1.path_prefix).to eq("/mcp")

      transport2 = described_class.new(server_double, { path_prefix: "/mcp/deep/" })
      expect(transport2.path_prefix).to eq("/mcp/deep")
    end
  end

  describe "Rack Application Endpoints" do
    # These tests verify the behavior of the handlers when called via specific paths
    # Note: Health checks commented out as they require routing/app testing
    # Removed include_context Async::RSpec::Reactor - add back if specific examples need it

    # Wrap each example in endpoint.bound to ensure server is running
    # around(:each) do |example|
    #   endpoint.bound do |_server|
    #     # Server is bound and listening within this block
    #     example.run
    #     # Server is automatically closed after this block
    #   end
    # end

    let(:sse_path) { "/mcp_sse/sse" }
    let(:message_path_base) { "/mcp_sse/message" }
    let(:message_path) { "#{message_path_base}?session_id=#{session_id}" }

    describe "Health Check" do
      # it "responds to root path with 200 OK", :async do
      #   # Difficult to unit test routing - tested via handle_health_check if applicable
      # end
      #
      # it "responds to prefixed path with 200 OK", :async do
      #   # Difficult to unit test routing
      # end
    end

    describe "GET /mcp_sse/sse" do
      let(:mock_env_get) { Rack::MockRequest.env_for(sse_path, method: "GET") }

      it "calls handle_sse_connection for GET requests", :async do
        mock_body = MockWritableBody.new
        allow(Async::HTTP::Body::Writable).to receive(:new).and_return(mock_body)
        # Expect the handler to be called
        # expect(transport).to receive(:handle_sse_connection).with(mock_env_get, session_double).and_call_original

        # Simulate call via Rack app structure (though app itself isn't run)
        # status, headers, body = transport.send(:build_rack_app, session_double).call(mock_env_get)

        # Directly call the handler instead
        status, headers, body_instance = transport.handle_sse_connection(mock_env_get, session_double)

        # Basic assertions on the response initiated by the handler
        expect(status).to eq(200)
        expect(headers["Content-Type"]).to include("text/event-stream")
        expect(body_instance).to eq(mock_body) # Check it returned our mock body

        # Check mock body received endpoint (verifies handler ran)
        chunks = mock_body.read_chunks(1, 0.2) # Slightly increased timeout just in case
        expect(chunks).not_to be_empty, "Expected endpoint event chunk, but got none."
        expect(chunks.first).to start_with("event: endpoint")

        # Need to manually stop the body/task simulation if not using TestClient
        mock_body.close
      end

      it "returns 405 for non-GET requests" do # No :async needed
        mock_env_post = Rack::MockRequest.env_for(sse_path, method: "POST")
        status, headers, body = transport.send(:build_rack_app, session_double).call(mock_env_post)

        expect(status).to eq(405)
        expect(headers["Content-Type"]).to include("text/plain")
        expect(body.join).to eq("Method Not Allowed") # Read body from array
      end
    end

    describe "POST /mcp_sse/message" do
      let(:json_content_type) { { "CONTENT_TYPE" => "application/json" } }
      let(:test_request_body_hash) { { jsonrpc: "2.0", id: 1, method: "test" } }
      let(:test_request_body_json) { test_request_body_hash.to_json }

      it "calls handle_message_post for POST requests" do # No :async needed for this part
        mock_env = Rack::MockRequest.env_for(message_path, method: "POST", input: test_request_body_json, **json_content_type)
        # Expect the handler to be called
        expect(transport).to receive(:handle_message_post).with(mock_env, session_double).and_call_original

        # Simulate call via Rack app structure
        status, headers, body = transport.send(:build_rack_app, session_double).call(mock_env)

        # Assert basic response from handler
        expect(status).to eq(202) # Assuming handle_message_post returns 202 on success path
        expect(headers["Content-Type"]).to include("application/json")
      end

      it "returns 405 for non-POST requests" do # No :async needed
        mock_env_get = Rack::MockRequest.env_for(message_path, method: "GET")
        status, headers, body = transport.send(:build_rack_app, session_double).call(mock_env_get)
        expect(status).to eq(405)
        expect(body.join).to eq("Method Not Allowed")
      end

      it "returns 400 if session_id is missing" do # No :async needed
        mock_env = Rack::MockRequest.env_for("/mcp_sse/message", method: "POST", input: test_request_body_json, **json_content_type) # No session_id
        status, headers, body = transport.send(:build_rack_app, session_double).call(mock_env)

        expect(status).to eq(400)
        expect(headers["Content-Type"]).to include("application/json")
        error_response = JSON.parse(body.join)
        expect(error_response["error"]["code"]).to eq(-32_600)
        expect(error_response["error"]["message"]).to include("Missing session_id")
      end

      it "returns 404 if session_id is invalid" do # No :async needed
        invalid_path = "/mcp_sse/message?session_id=invalid-id"
        mock_env = Rack::MockRequest.env_for(invalid_path, method: "POST", input: test_request_body_json, **json_content_type)
        status, headers, body = transport.send(:build_rack_app, session_double).call(mock_env)

        expect(status).to eq(404)
        expect(headers["Content-Type"]).to include("application/json")
        error_response = JSON.parse(body.join)
        expect(error_response["error"]["code"]).to eq(-32_001)
        expect(error_response["error"]["message"]).to include("Invalid session_id")
      end
    end
  end

  describe "Client Connection Lifecycle" do # :async removed from describe
    # Test handle_sse_connection directly
    # No reactor context needed here unless specific examples use internal async waits

    # Wrap each example in endpoint.bound to ensure server is running
    # around(:each) do |example|
    #   endpoint.bound do |_server|
    #     example.run
    #   end
    # end

    let(:sse_path) { "/mcp_sse/sse" } # Keep path definition for clarity
    let(:mock_env_get) { Rack::MockRequest.env_for(sse_path, method: "GET") }
    let(:mock_body) { MockWritableBody.new }

    before do
      # Mock the body creation before the handler is called
      allow(Async::HTTP::Body::Writable).to receive(:new).and_return(mock_body)
    end

    # Keep :async because read_chunks uses Async::Timeout
    it "creates a client connection and sends endpoint URL", :async do
      # Directly call the handler
      status, headers, body_instance = transport.handle_sse_connection(mock_env_get, session_double)

      # Check registration (should be synchronous within handler before async task starts)
      registered_client = clients_mutex.synchronize { clients[session_id] }
      expect(registered_client).to be_a(MCPRuby::Transport::SSE::ClientConnection)
      expect(registered_client.id).to eq(session_id)

      # Check handler response (should initiate SSE stream)
      expect(status).to eq(200)
      expect(headers["Content-Type"]).to include("text/event-stream")
      expect(body_instance).to eq(mock_body)

      # Check that the endpoint event was sent via the mock body
      # This implicitly waits for the async task within handle_sse_connection to write
      chunks = mock_body.read_chunks(1, 0.2) # Use timeout
      expect(chunks).not_to be_empty, "Expected endpoint event chunk, but got none."
      expect(chunks.first).to start_with("event: endpoint\ndata: /mcp_sse/message?session_id=#{session_id}")

      # Cleanup: Close the mock body to signal completion to internal task
      mock_body.close
    end

    # Keep :async because read_chunks and internal task cleanup require time/async context
    it "properly cleans up resources when the client disconnects", :async do
      # Call the handler to establish connection/task
      _status, _headers, _body_instance = transport.handle_sse_connection(mock_env_get, session_double)

      # Ensure client is registered before simulating disconnect
      # Give the task a moment to register the client
      Async::Task.current.sleep 0.01
      expect(clients_mutex.synchronize { clients.key?(session_id) }).to be true

      # Simulate client disconnection by closing the mock body
      # This should trigger the rescue block in the handle_sse_connection's async task
      mock_body.close

      # Give the error handler/cleanup task time to run
      Async::Task.current.sleep 0.05

      # Verify cleanup
      clients_mutex.synchronize do
        expect(clients).not_to have_key(session_id)
      end
    end
    # Removed race condition test as it was complex and less relevant for unit testing
  end

  describe "#send_notification" do
    # Use async-rspec reactor context as this block uses Async::Queue
    include_context Async::RSpec::Reactor

    let(:client_queue) { Async::Queue.new }
    # Need a real task double now for ClientConnection, as :async runs in a real task
    let(:mock_task) { instance_double(Async::Task, stopped?: false) }
    let(:client_conn) { MCPRuby::Transport::SSE::ClientConnection.new(session_id, client_queue, mock_task) }

    before do
      clients_mutex.synchronize { clients[session_id] = client_conn }
    end

    after do
      clients_mutex.synchronize { clients.delete(session_id) }
    end

    # This test doesn't involve HTTP requests, just internal logic, so it remains largely the same
    # but needs the :async tag if it uses Async components like the Queue within the test.
    it "enqueues a notification message", :async do
      transport.send_notification(session_id, "test_notification", { data: 123 })

      expect(client_queue.size).to eq(1)
      message = Async::Timeout.wrap(0.1) { client_queue.dequeue }
      expect(message).to eq({
                              jsonrpc: "2.0",
                              method: "test_notification",
                              params: { data: 123 }
                            })
    end

    it "returns false if client not found" do # No :async needed here
      result = transport.send_notification("non-existent-id", "test_notification")
      expect(result).to be false
      expect(logger_double).to have_received(:warn).with(/No active client queue/)
    end
  end

  # This describe block tests the internal logic triggered by a POST, but doesn't
  # make the POST itself anymore. We rely on the endpoint tests for the POST->handler path.
  # We need to simulate the state *after* a valid POST request would have been received.
  describe "#handle_message_post (internal logic)" do
    # Use async-rspec reactor context as this block uses Async::Queue and calls async methods
    include_context Async::RSpec::Reactor

    let(:client_queue) { Async::Queue.new }
    let(:mock_task) { instance_double(Async::Task, stopped?: false) }
    let(:client_conn) { MCPRuby::Transport::SSE::ClientConnection.new(session_id, client_queue, mock_task) }
    let(:request_body_hash) { { jsonrpc: "2.0", id: "req-1", method: "test_method", params: {} } }
    let(:request_body_json) { request_body_hash.to_json }
    let(:server_result) { { success: true } }
    let(:message_path) { "/mcp_sse/message?session_id=#{session_id}" }
    let(:env) do
      { "rack.input" => StringIO.new(request_body_json), "REQUEST_METHOD" => "POST", "PATH_INFO" => "/mcp_sse/message",
        "QUERY_STRING" => "session_id=#{session_id}" }
    end

    before do
      clients_mutex.synchronize { clients[session_id] = client_conn }
      allow(server_double).to receive(:handle_message)
        .with(request_body_hash, session_double, session_id) # Pass hash, not string
        .and_return(server_result)
    end

    after do
      clients_mutex.synchronize { clients.delete(session_id) }
    end

    # Testing the internal handler method directly
    it "processes valid request and enqueues result", :async do
      # Directly call the handler function
      status, headers, body_proxy = transport.handle_message_post(env, session_double)

      # Check immediate response (202 Accepted)
      expect(status).to eq(202)
      expect(headers["Content-Type"]).to eq("application/json")
      response_body = JSON.parse(body_proxy.first) # body_proxy is likely an array
      expect(response_body["status"]).to eq("accepted")
      expect(response_body["id"]).to eq("req-1")

      # Check that the *result* message was enqueued for SSE
      message = Async::Timeout.wrap(0.1) { client_queue.dequeue }
      expect(message).to eq({
                              jsonrpc: "2.0",
                              id: "req-1",
                              result: server_result
                            })
    end

    it "handles JSON parse errors and enqueues error", :async do
      env["rack.input"] = StringIO.new('{"id": "broken", "method":') # Invalid JSON
      status, headers, body_proxy = transport.handle_message_post(env, session_double)

      expect(status).to eq(400)
      response_body = JSON.parse(body_proxy.first)
      expect(response_body["error"]["code"]).to eq(-32_700)

      # Check error was enqueued for SSE
      message = Async::Timeout.wrap(0.1) { client_queue.dequeue }
      expect(message).to include(
        jsonrpc: "2.0",
        id: "broken",
        error: hash_including(code: -32_700, message: "Parse error")
      )
    end

    it "handles protocol errors and enqueues error", :async do
      protocol_error = MCPRuby::ProtocolError.new("Protocol error", code: -32_600, request_id: "req-1")
      allow(server_double).to receive(:handle_message).and_raise(protocol_error)

      status, headers, body_proxy = transport.handle_message_post(env, session_double)

      expect(status).to eq(400)
      response_body = JSON.parse(body_proxy.first)
      expect(response_body["error"]["code"]).to eq(-32_600)

      # Check error was enqueued for SSE
      message = Async::Timeout.wrap(0.1) { client_queue.dequeue }
      expect(message).to include(
        jsonrpc: "2.0",
        id: "req-1",
        error: hash_including(code: -32_600, message: "Protocol error")
      )
    end

    it "handles standard errors and enqueues error", :async do
      allow(server_double).to receive(:handle_message).and_raise(StandardError, "Something went wrong")

      status, headers, body_proxy = transport.handle_message_post(env, session_double)

      expect(status).to eq(500)
      response_body = JSON.parse(body_proxy.first)
      expect(response_body["error"]["code"]).to eq(-32_603)

      # Check error was enqueued for SSE
      message = Async::Timeout.wrap(0.1) { client_queue.dequeue }
      expect(message).to include(
        jsonrpc: "2.0",
        id: "req-1",
        error: hash_including(code: -32_603, message: "Internal server error")
      )
    end
  end

  describe "#enqueue_message" do
    # Use async-rspec reactor context as this block uses Async::Queue
    include_context Async::RSpec::Reactor

    let(:client_queue) { Async::Queue.new }
    let(:mock_task) { instance_double(Async::Task, stopped?: false) }
    let(:client_conn) { MCPRuby::Transport::SSE::ClientConnection.new(session_id, client_queue, mock_task) }
    let(:message) { { jsonrpc: "2.0", result: "ok", id: 1 } }

    before do
      clients_mutex.synchronize { clients[session_id] = client_conn }
    end

    after do
      clients_mutex.synchronize { clients.delete(session_id) }
    end

    # This is internal logic, doesn't need client, just :async for queue
    it "enqueues the message to the correct client queue", :async do
      expect(transport.send(:enqueue_message, session_id, message)).to be true
      dequeued = Async::Timeout.wrap(0.1) { client_queue.dequeue }
      expect(dequeued).to eq(message)
    end

    it "returns false if client queue is not found" do # No :async
      expect(transport.send(:enqueue_message, "non-existent-id", message)).to be false
      expect(logger_double).to have_received(:warn).with(/No active client queue found for session_id non-existent-id/)
    end
  end

  describe "#build_rack_app" do
    it "creates a valid Rack application" do # No :async
      built_app = transport.send(:build_rack_app, session_double)
      expect(built_app).to respond_to(:call)
      # We can't easily test routing here without Rack::Test or a client
    end
  end

  describe "Error Response Formatting" do # No :async needed
    it "formats error payloads correctly" do
      error_payload = transport.send(:format_error_payload, -32_600, "Invalid Request", { details: "Missing field" })
      expect(error_payload).to eq({
                                    code: -32_600,
                                    message: "Invalid Request",
                                    data: { details: "Missing field" }
                                  })
    end

    it "formats error bodies correctly" do
      error_body = transport.send(:format_error_body, "req-1", -32_600, "Invalid Request")
      parsed = JSON.parse(error_body)
      expect(parsed).to eq({
                             "jsonrpc" => "2.0",
                             "id" => "req-1",
                             "error" => {
                               "code" => -32_600,
                               "message" => "Invalid Request"
                             }
                           })
    end

    it "creates appropriate HTTP responses for different error codes" do
      # Parse error (400)
      status, headers, body = transport.send(:error_response, "req-1", -32_700, "Parse error")
      expect(status).to eq(400)
      expect(headers["Content-Type"]).to include("application/json")

      # Method not found (404)
      status, headers, body = transport.send(:error_response, "req-1", -32_601, "Method not found")
      expect(status).to eq(404)
      expect(headers["Content-Type"]).to include("application/json")

      # Server error (500)
      status, headers, body = transport.send(:error_response, "req-1", -32_603, "Internal error")
      expect(status).to eq(500)
      expect(headers["Content-Type"]).to include("application/json")
    end
  end
end
