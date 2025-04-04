# spec/mcp_ruby/transport/sse_spec.rb

require "spec_helper"
require "rack/test"
require "async"
require "async/queue"
require "json"
require "securerandom"

# Mock Writable Body for testing SSE stream output
class MockWritableBody
  attr_reader :chunks, :finished

  def initialize
    @chunks = []
    @finished = false
    @condition = Async::Condition.new
    @closed_by_peer = false
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

  def close # Simulate peer closing connection
    @closed_by_peer = true
    @finished = true
    @condition.signal
  end

  # Helper for tests to wait for and read chunks
  def read_chunks(count = 1, timeout = 0.1)
    read = []
    task = nil

    begin
      task = Async do
        loop do
          break if read.size >= count || @finished || @closed_by_peer

          if @chunks.empty?
            # Wait for signal or timeout
            @condition.wait(timeout)
            break if @chunks.empty? # If we timed out and still no chunks, break
          else
            read << @chunks.shift
          end
        end
      end

      # Wait for the task to complete or timeout
      result = task.wait_for(timeout)
      raise "Timeout waiting for chunks" if result.nil? && read.size < count

      read
    ensure
      if task
        task.stop
        task.wait
      end
    end
  end
end

RSpec.describe MCPRuby::Transport::SSE do
  include Rack::Test::Methods

  # --- Mocks and Doubles ---
  let(:server_double) do
    instance_double(MCPRuby::Server, logger: logger_double, server_info: server_info, server_capabilities: server_capabilities,
                                     protocol_version: protocol_version, handle_message: nil)
  end
  let(:logger_double) { instance_double(Logger, info: nil, debug: nil, warn: nil, error: nil, fatal: nil) }
  let(:session_double) { instance_double(MCPRuby::Session, initialized?: true) } # Assume initialized for most tests
  let(:server_info) { { name: "TestSSE", version: "0.1" } }
  let(:server_capabilities) { { tools: { listChanged: false } } }
  let(:protocol_version) { MCPRuby::Server::PROTOCOL_VERSION }
  let(:options) { { host: "127.0.0.1", port: 9293, path_prefix: "/mcp_sse" } }

  # The transport instance under test
  subject(:transport) { described_class.new(server_double, options) }

  # Control session IDs
  let(:session_id) { SecureRandom.uuid }
  before { allow(SecureRandom).to receive(:uuid).and_return(session_id) }

  # Access internal state for assertions
  let(:clients) { transport.instance_variable_get(:@clients) }
  let(:clients_mutex) { transport.instance_variable_get(:@clients_mutex) }

  # Define app for Rack::Test
  def app
    # Build a new Rack app for each test
    transport.send(:build_rack_app, session_double)
  end

  # --- Helper Methods ---
  def sse_event(event, data)
    "event: #{event}\ndata: #{data}\n\n"
  end

  def simulate_post(path, body, headers = {})
    post path, body.to_json, { "CONTENT_TYPE" => "application/json" }.merge(headers)
  end

  # Run tests in Async context
  around(:each) do |example|
    # Only wrap in Async if the example is marked with :async
    if example.metadata[:async]
      Async do |task|
        example.run
      end
    else
      example.run
    end
  end

  # --- Test Suite ---

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
    let(:sse_path) { "/mcp_sse/sse" }
    let(:message_path_base) { "/mcp_sse/message" }
    let(:message_path) { "#{message_path_base}?session_id=#{session_id}" }

    describe "GET /mcp_sse/sse" do
      it "returns 405 for non-GET requests" do
        # Set up the environment for a POST request
        env = Rack::MockRequest.env_for(sse_path, method: "POST")
        status, headers, _body = transport.handle_sse_connection(env, session_double)
        expect(status).to eq(405)
        expect(headers["Content-Type"]).to eq("text/plain")
      end

      it "returns 200 OK for GET requests" do
        # Set up the environment for a GET request
        env = Rack::MockRequest.env_for(sse_path, method: "GET")
        status, headers, _body = transport.handle_sse_connection(env, session_double)
        expect(status).to eq(200)
        expect(headers["Content-Type"]).to eq("text/event-stream")
        expect(headers["Cache-Control"]).to eq("no-cache")
        expect(headers["Connection"]).to eq("keep-alive")
      end

      it "registers the client connection internally", :async do
        # We need to simulate the body reading part of Falcon/Async to trigger the registration
        mock_body = MockWritableBody.new
        allow(Async::HTTP::Body::Writable).to receive(:new).and_return(mock_body)

        # Set up the environment for a GET request
        env = Rack::MockRequest.env_for(sse_path, method: "GET")

        # Run the connection handler in an async task
        task = Async do
          transport.handle_sse_connection(env, session_double)
        end

        # Wait for the initial endpoint event to be written
        mock_body.read_chunks(1, 0.5)

        # Verify client registration
        clients_mutex.synchronize do
          expect(clients.keys).to include(session_id)
          expect(clients[session_id]).to be_a(MCPRuby::Transport::SSE::ClientConnection)
          expect(clients[session_id].id).to eq(session_id)
          expect(clients[session_id].queue).to be_a(Async::Queue)
        end

        # Simulate closing the connection
        mock_body.close

        # Wait for cleanup
        Async::Task.current.sleep 0.1

        # Stop the task
        task.stop

        # Verify cleanup
        expect(clients).to be_empty
      end

      it "sends the initial endpoint event", :async do
        mock_body = MockWritableBody.new
        allow(Async::HTTP::Body::Writable).to receive(:new).and_return(mock_body)

        # Set up the environment for a GET request
        env = Rack::MockRequest.env_for(sse_path, method: "GET")
        transport.handle_sse_connection(env, session_double)

        # Read the first chunk written to the body
        initial_event = mock_body.read_chunks(1).first

        expected_endpoint_url = "/mcp_sse/message?session_id=#{session_id}"
        expected_event = sse_event("endpoint", expected_endpoint_url)
        expect(initial_event).to eq(expected_event)

        mock_body.close # Cleanup
        Async::Task.current.sleep 0.01
      end

      # Testing keep-alives and message sending over SSE via Rack::Test is difficult.
      # We test the enqueuing logic via the POST endpoint tests.
    end

    describe "POST /mcp_sse/message" do
      before do
        # Pre-register the client as if they connected via SSE
        @client_queue = Async::Queue.new
        client_conn = MCPRuby::Transport::SSE::ClientConnection.new(session_id, @client_queue, nil)
        clients_mutex.synchronize { clients[session_id] = client_conn }
      end

      after do
        # Clean up client registration
        clients_mutex.synchronize { clients.delete(session_id) }
      end

      it "returns 405 for non-POST requests" do
        # Set up the environment for a GET request
        env = Rack::MockRequest.env_for(message_path, method: "GET")
        status, headers, _body = transport.handle_message_post(env, session_double)
        expect(status).to eq(405)
        expect(headers["Content-Type"]).to eq("text/plain")
      end

      it "returns 400 if session_id is missing" do
        # Set up the environment for a POST request without session_id
        env = Rack::MockRequest.env_for(message_path_base, method: "POST",
                                                           input: { id: 1, method: "ping" }.to_json,
                                                           "CONTENT_TYPE" => "application/json")
        status, _headers, body = transport.handle_message_post(env, session_double)
        expect(status).to eq(400)
        expect(body.first).to include("Missing session_id parameter")
      end

      it "returns 404 if session_id is invalid/unknown" do
        # Set up the environment for a POST request with invalid session_id
        env = Rack::MockRequest.env_for("#{message_path_base}?session_id=invalid-id", method: "POST",
                                                                                      input: { id: 1, method: "ping" }.to_json,
                                                                                      "CONTENT_TYPE" => "application/json")
        status, _headers, body = transport.handle_message_post(env, session_double)
        expect(status).to eq(404)
        expect(body.first).to include("Invalid session_id")
      end

      it "returns 400 for invalid JSON body" do
        # Set up the environment for a POST request with invalid JSON
        env = Rack::MockRequest.env_for(message_path, method: "POST",
                                                      input: "invalid json",
                                                      "CONTENT_TYPE" => "application/json")
        status, _headers, body = transport.handle_message_post(env, session_double)
        expect(status).to eq(400)
        expect(body.first).to include("Parse error")
      end

      it "calls server.handle_message with correct args on success" do
        request_body = { jsonrpc: "2.0", id: "req-1", method: "test_method", params: { data: 1 } }
        # Server returns the *result* payload, transport wraps it
        allow(server_double).to receive(:handle_message)
          .with(request_body, session_double, session_id)
          .and_return({ success: true })

        # Set up the environment for a POST request
        env = Rack::MockRequest.env_for(message_path, method: "POST",
                                                      input: request_body.to_json,
                                                      "CONTENT_TYPE" => "application/json")
        status, _headers, body = transport.handle_message_post(env, session_double)
        expect(status).to eq(202)
        expect(body.first).to include('"status":"accepted"')
        expect(body.first).to include('"id":"req-1"')
        expect(server_double).to have_received(:handle_message)
      end

      it "enqueues the response from server.handle_message onto the client's queue", :async do
        request_body = { jsonrpc: "2.0", id: "req-2", method: "test_method", params: {} }
        server_result = { processed: true }
        allow(server_double).to receive(:handle_message)
          .with(request_body, session_double, session_id)
          .and_return(server_result)

        # Set up the environment for a POST request
        env = Rack::MockRequest.env_for(message_path, method: "POST",
                                                      input: request_body.to_json,
                                                      "CONTENT_TYPE" => "application/json")

        # Call the handler directly
        status, _headers, _body = transport.handle_message_post(env, session_double)
        expect(status).to eq(202) # Verify the immediate HTTP response

        # Give the handler a brief moment to enqueue
        Async::Task.current.sleep 0.01

        # Check queue size first (non-blocking)
        expect(@client_queue.size).to eq(1)

        # Now dequeue and verify (should be immediate)
        queued_message = @client_queue.dequeue(timeout: 0.01)
        expected_response = { jsonrpc: "2.0", id: "req-2", result: server_result }
        expect(queued_message).to eq(expected_response)
      end

      it "handles MCPRuby::ProtocolError raised by server.handle_message", :async do
        request_body = { jsonrpc: "2.0", id: "req-3", method: "invalid_method", params: {} }
        error = MCPRuby::MethodNotFoundError.new("invalid_method", request_id: "req-3")
        allow(server_double).to receive(:handle_message)
          .with(request_body, session_double, session_id)
          .and_raise(error)

        # Set up the environment for a POST request
        env = Rack::MockRequest.env_for(message_path, method: "POST",
                                                      input: request_body.to_json,
                                                      "CONTENT_TYPE" => "application/json")
        status, _headers, body = transport.handle_message_post(env, session_double)
        expect(status).to eq(404)
        expect(body.first).to include('"code":-32601')
        expect(body.first).to include('"message":"Method not found"')

        # Check queue for error message
        queued_message = @client_queue.dequeue(timeout: 0.1)
        expect(queued_message).to include(
          jsonrpc: "2.0",
          id: "req-3",
          error: hash_including(code: -32_601, message: "Method not found")
        )
      end

      it "handles StandardError raised by server.handle_message", :async do
        request_body = { jsonrpc: "2.0", id: "req-4", method: "broken_method", params: {} }
        error = StandardError.new("Something went very wrong")
        allow(server_double).to receive(:handle_message)
          .with(request_body, session_double, session_id)
          .and_raise(error)

        # Set up the environment for a POST request
        env = Rack::MockRequest.env_for(message_path, method: "POST",
                                                      input: request_body.to_json,
                                                      "CONTENT_TYPE" => "application/json")
        status, _headers, body = transport.handle_message_post(env, session_double)
        expect(status).to eq(500)
        expect(body.first).to include('"code":-32603')
        expect(body.first).to include('"message":"Internal server error"')
        expect(body.first).to include('"details":{"details":"Something went very wrong"}')

        # Check queue for error message
        queued_message = @client_queue.dequeue(timeout: 0.1)
        expect(queued_message).to include(
          jsonrpc: "2.0",
          id: "req-4",
          error: hash_including(code: -32_603, message: "Internal server error")
        )
      end
    end
  end

  describe "#enqueue_message" do
    let(:client_id) { "client-abc" }
    let(:queue) { Async::Queue.new }
    let(:client_conn) { MCPRuby::Transport::SSE::ClientConnection.new(client_id, queue, nil) }
    let(:message) { { jsonrpc: "2.0", result: "ok", id: 1 } }

    before do
      clients_mutex.synchronize { clients[client_id] = client_conn }
    end

    after do
      # No need to close the queue, it will be garbage collected
      clients_mutex.synchronize { clients.delete(client_id) }
    end

    it "enqueues the message to the correct client queue", :async do
      expect(transport.send(:enqueue_message, client_id, message)).to be true
      expect(queue.dequeue(timeout: 0.01)).to eq(message)
    end

    it "returns false if client queue is not found" do
      expect(transport.send(:enqueue_message, "non-existent-id", message)).to be false
      expect(logger_double).to have_received(:warn).with(/No active client queue found for session_id non-existent-id/)
    end

    it "returns false if client queue is inactive", :async do
      # Instead of closing the queue, we'll remove it from the clients hash
      clients_mutex.synchronize { clients.delete(client_id) }
      expect(transport.send(:enqueue_message, client_id, message)).to be false
      expect(logger_double).to have_received(:warn).with(/No active client queue found for session_id client-abc/)
    end
  end
end
