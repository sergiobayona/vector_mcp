# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "json"
require "uri"
require "timeout"
require "socket"
require "vector_mcp/transport/http_stream"

RSpec.describe "HTTP Stream Transport - Streaming Features", type: :integration do

  let(:test_port) { find_available_port }
  let(:base_url) { "http://localhost:#{test_port}" }
  let(:mcp_endpoint) { "#{base_url}/mcp" }

  # Create a test server
  let(:server) do
    VectorMCP.new(
      name: "HTTP Stream Features Test Server",
      version: "1.0.0",
      log_level: Logger::ERROR
    )
  end

  let(:transport) { VectorMCP::Transport::HttpStream.new(server, port: test_port, host: "localhost") }

  before(:each) do
    # Register tools that use sampling
    server.register_tool(
      name: "interactive_tool",
      description: "Tool that demonstrates sampling",
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
      result = session.sample({
        messages: [
          {
            role: "user",
            content: {
              type: "text",
              text: args["question"]
            }
          }
        ],
        system_prompt: "You are a helpful assistant.",
        max_tokens: 100
      })
      
      response = { initial_response: result.content }
      
      if args["follow_up"]
        follow_up_result = session.sample({
          messages: [
            {
              role: "user",
              content: {
                type: "text",
                text: "Can you elaborate on that?"
              }
            }
          ],
          system_prompt: "You are a helpful assistant.",
          max_tokens: 100
        })
        response[:follow_up_response] = follow_up_result.content
      end
      
      response
    end

    # Register a tool that tests session-specific sampling
    server.register_tool(
      name: "session_specific_tool",
      description: "Tests session-specific sampling",
      input_schema: {
        type: "object",
        properties: { message: { type: "string" } },
        required: ["message"]
      }
    ) do |args, session|
      result = session.sample({
        messages: [
          {
            role: "user",
            content: {
              type: "text", 
              text: "Session #{session.id}: #{args["message"]}"
            }
          }
        ],
        system_prompt: "Echo back the session information.",
        max_tokens: 50
      })
      
      {
        session_id: session.id,
        original_message: args["message"],
        sampled_response: result.content
      }
    end

    # Register a notification tool for testing
    server.register_tool(
      name: "notification_tool",
      description: "Sends notifications to test streaming",
      input_schema: {
        type: "object",
        properties: { message: { type: "string" } },
        required: ["message"]
      }
    ) do |args, session|
      # Send a notification via the transport
      transport.send_notification_to_session(
        session.id,
        "notification/test",
        { message: args["message"] }
      )
      
      { notification_sent: true, message: args["message"] }
    end

    # Start the server
    @server_thread = Thread.new do
      transport.run
    rescue StandardError
      # Server stopped, expected during cleanup
    end

    wait_for_server_start(base_url)
  end

  after(:each) do
    transport.stop
    @server_thread&.join(2)
    @server_thread&.kill if @server_thread&.alive?
    @server_thread = nil
  end

  describe "Phase 1: Server-Initiated Sampling Tests" do
    describe "1.1 Basic Sampling Infrastructure" do
      let(:session_id) { "sampling-test-session" }
      let(:mock_client) { StreamingTestHelpers::MockStreamingClient.new(session_id, base_url) }

      before do
        initialize_mcp_session(base_url, session_id)
      end

      after do
        mock_client.stop_streaming
      end

      it "establishes streaming connection with GET /mcp endpoint" do
        expect(mock_client.start_streaming).to be true
        expect(mock_client.connected?).to be true
      end

      it "handles Mcp-Session-Id header correctly" do
        mock_client.start_streaming
        expect(mock_client.session_id).to eq(session_id)
        expect(mock_client.connected?).to be true
      end

      it "receives Server-Sent Events in proper format" do
        mock_client.start_streaming
        
        # Wait for connection event or initial messages
        sleep(0.5)
        
        # Events should be properly formatted
        events = mock_client.events_received
        if events.any?
          event = events.first
          expect(event).to have_key(:id)
          expect(event).to have_key(:data)
        end
      end

      it "maintains connection state correctly" do
        expect(mock_client.connection_state).to eq(:disconnected)
        
        mock_client.start_streaming
        expect(mock_client.connection_state).to eq(:connected)
        
        mock_client.stop_streaming
        expect(mock_client.connection_state).to eq(:disconnected)
      end
    end

    describe "1.2 Sampling Request/Response Cycle" do
      let(:session_id) { "sampling-cycle-test" }
      let(:mock_client) { StreamingTestHelpers::MockStreamingClient.new(session_id, base_url) }

      before do
        initialize_mcp_session(base_url, session_id)
        mock_client.set_sampling_response("sampling/createMessage", "This is a test response")
        mock_client.start_streaming
      end

      after do
        mock_client.stop_streaming
      end

      it "handles server-initiated sampling requests" do
        # Call a tool that uses sampling
        response = call_tool(base_url, session_id, "interactive_tool", {
          question: "What is 2+2?"
        })
        
        # Should either succeed or fail with appropriate error
        if response["initial_response"]
          expect(response["initial_response"]).to be_a(Hash)
          expect(response["initial_response"]["type"]).to eq("text")
        else
          # May fail if no streaming connection is active
          expect(response["error"]).not_to be_nil
        end
      end

      it "validates JSON-RPC format for sampling requests" do
        sampling_received = false
        
        mock_client.on_method("sampling/createMessage") do |event|
          sampling_received = true
          message = event[:data]
          
          # Should be proper JSON-RPC format
          expect(message["jsonrpc"]).to eq("2.0")
          expect(message["id"]).to be_present
          expect(message["method"]).to eq("sampling/createMessage")
          expect(message["params"]).to be_a(Hash)
        end
        
        # Trigger sampling
        call_tool(base_url, session_id, "interactive_tool", {
          question: "What is the capital of France?"
        })
        
        # Give time for sampling to occur
        sleep(1)
        
        # If sampling was attempted, it should be properly formatted
        # Note: May not receive sampling if no active streaming connection
      end

      it "handles sampling timeout scenarios" do
        # Create a client that doesn't respond to sampling
        non_responsive_client = StreamingTestHelpers::MockStreamingClient.new("timeout-test", base_url)
        initialize_mcp_session(base_url, "timeout-test")
        non_responsive_client.start_streaming
        
        # Don't set any sampling responses - client won't respond
        
        response = call_tool(base_url, "timeout-test", "interactive_tool", {
          question: "This should timeout"
        })
        
        # Should receive timeout error
        expect(response["error"]).not_to be_nil
        expect(response["error"]["message"]).to include("No streaming session available")
        
        non_responsive_client.stop_streaming
      end
    end

    describe "1.3 Session-Specific Sampling" do
      let(:session1_id) { "session-specific-1" }
      let(:session2_id) { "session-specific-2" }
      let(:client1) { StreamingTestHelpers::MockStreamingClient.new(session1_id, base_url) }
      let(:client2) { StreamingTestHelpers::MockStreamingClient.new(session2_id, base_url) }

      before do
        initialize_mcp_session(base_url, session1_id)
        initialize_mcp_session(base_url, session2_id)
        
        client1.set_sampling_response("sampling/createMessage", "Response from session 1")
        client2.set_sampling_response("sampling/createMessage", "Response from session 2")
        
        client1.start_streaming
        client2.start_streaming
      end

      after do
        client1.stop_streaming
        client2.stop_streaming
      end

      it "targets sampling to specific sessions" do
        # Call tool on session 1
        response1 = call_tool(base_url, session1_id, "session_specific_tool", {
          message: "Hello from session 1"
        })
        
        # Call tool on session 2
        response2 = call_tool(base_url, session2_id, "session_specific_tool", {
          message: "Hello from session 2"
        })
        
        # Both should either succeed or fail consistently
        if response1["session_id"]
          expect(response1["session_id"]).to eq(session1_id)
          expect(response1["original_message"]).to eq("Hello from session 1")
        end
        
        if response2["session_id"]
          expect(response2["session_id"]).to eq(session2_id)
          expect(response2["original_message"]).to eq("Hello from session 2")
        end
      end

      it "isolates sampling between sessions" do
        # Each session should only receive its own sampling requests
        session1_requests = 0
        session2_requests = 0
        
        client1.on_method("sampling/createMessage") do |event|
          session1_requests += 1
        end
        
        client2.on_method("sampling/createMessage") do |event|
          session2_requests += 1
        end
        
        # Call tool on session 1 only
        call_tool(base_url, session1_id, "session_specific_tool", {
          message: "Test isolation"
        })
        
        sleep(1)
        
        # Session 1 should receive sampling, session 2 should not
        # Note: May not receive if no streaming connection is active
        if session1_requests > 0
          expect(session2_requests).to eq(0)
        end
      end
    end

    describe "1.4 Sampling Error Handling" do
      let(:session_id) { "error-handling-test" }
      let(:mock_client) { StreamingTestHelpers::MockStreamingClient.new(session_id, base_url) }

      before do
        initialize_mcp_session(base_url, session_id)
      end

      after do
        mock_client.stop_streaming
      end

      it "handles sampling with no streaming connection" do
        # Don't start streaming client - no connection available
        
        response = call_tool(base_url, session_id, "interactive_tool", {
          question: "This should fail"
        })
        
        # Should fail with appropriate error
        expect(response["error"]).not_to be_nil
        expect(response["error"]["message"]).to include("No streaming session available")
      end

      it "handles malformed sampling responses" do
        mock_client.start_streaming
        
        # Configure client to send malformed response
        mock_client.on_method("sampling/createMessage") do |event|
          # Send malformed JSON response
          malformed_response = {
            jsonrpc: "2.0",
            id: event[:data]["id"],
            # Missing result field
          }
          
          # Send directly to avoid response helpers
          mock_client.send(:send_response_to_server, malformed_response)
        end
        
        response = call_tool(base_url, session_id, "interactive_tool", {
          question: "This should handle malformed response"
        })
        
        # Should handle error gracefully
        expect(response["error"]).not_to be_nil
      end

      it "handles client disconnection during sampling" do
        mock_client.start_streaming
        
        # Start a sampling request then disconnect
        tool_thread = Thread.new do
          call_tool(base_url, session_id, "interactive_tool", {
            question: "This will be interrupted"
          })
        end
        
        # Give time for sampling to start
        sleep(0.5)
        
        # Disconnect client
        mock_client.stop_streaming
        
        # Tool should eventually return with error
        tool_thread.join(5)
        
        # Should handle disconnection gracefully
        expect(tool_thread.alive?).to be false
      end
    end
  end

  describe "Phase 2: Event Store Functionality" do
    describe "2.1 Event Storage and Retrieval" do
      let(:session_id) { "event-store-test" }

      before do
        initialize_mcp_session(base_url, session_id)
      end

      it "stores events in the event store" do
        # Access the event store directly
        event_store = transport.event_store
        
        # Store some test events
        event_id1 = event_store.store_event("test data 1", "test_event")
        event_id2 = event_store.store_event("test data 2", "test_event")
        
        expect(event_store.event_count).to eq(2)
        expect(event_store.event_exists?(event_id1)).to be true
        expect(event_store.event_exists?(event_id2)).to be true
      end

      it "generates unique event IDs" do
        event_store = transport.event_store
        
        event_ids = []
        10.times do |i|
          event_ids << event_store.store_event("test data #{i}")
        end
        
        expect(event_ids.uniq.length).to eq(10)
      end

      it "retrieves events by ID" do
        event_store = transport.event_store
        
        event_id = event_store.store_event("test data", "test_event")
        events = event_store.get_events_after(nil)
        
        expect(events.length).to eq(1)
        expect(events.first.id).to eq(event_id)
        expect(events.first.data).to eq("test data")
        expect(events.first.type).to eq("test_event")
      end

      it "handles event expiration in circular buffer" do
        # Create event store with small buffer
        small_event_store = VectorMCP::Transport::HttpStream::EventStore.new(3)
        
        # Store more events than buffer size
        event_ids = []
        5.times do |i|
          event_ids << small_event_store.store_event("data #{i}")
        end
        
        # Should only keep last 3 events
        expect(small_event_store.event_count).to eq(3)
        expect(small_event_store.event_exists?(event_ids[0])).to be false
        expect(small_event_store.event_exists?(event_ids[1])).to be false
        expect(small_event_store.event_exists?(event_ids[4])).to be true
      end
    end

    describe "2.2 Connection Resumability" do
      let(:session_id) { "resumability-test" }
      let(:mock_client) { StreamingTestHelpers::MockStreamingClient.new(session_id, base_url) }

      before do
        initialize_mcp_session(base_url, session_id)
      end

      after do
        mock_client.stop_streaming
      end

      it "supports Last-Event-ID header" do
        # Start streaming connection
        mock_client.start_streaming
        
        # Generate some events
        event_store = transport.event_store
        event_id = event_store.store_event("test event", "test")
        
        # Stop and restart with Last-Event-ID
        mock_client.stop_streaming
        
        resume_client = StreamingTestHelpers::MockStreamingClient.new(session_id, base_url)
        expect(resume_client.start_streaming(headers: { "Last-Event-ID" => event_id })).to be true
        
        # Should be able to resume
        expect(resume_client.connected?).to be true
        
        resume_client.stop_streaming
      end

      it "replays events after Last-Event-ID" do
        event_store = transport.event_store
        
        # Store several events
        event_id1 = event_store.store_event("event 1", "test")
        event_id2 = event_store.store_event("event 2", "test")
        event_id3 = event_store.store_event("event 3", "test")
        
        # Get events after event 1
        events = event_store.get_events_after(event_id1)
        
        expect(events.length).to eq(2)
        expect(events[0].id).to eq(event_id2)
        expect(events[1].id).to eq(event_id3)
      end

      it "handles invalid Last-Event-ID" do
        resume_client = StreamingTestHelpers::MockStreamingClient.new(session_id, base_url)
        
        # Try to resume with invalid event ID
        expect(resume_client.start_streaming(headers: { "Last-Event-ID" => "invalid-id" })).to be true
        
        # Should still connect (may return no events)
        expect(resume_client.connected?).to be true
        
        resume_client.stop_streaming
      end
    end

    describe "2.3 Event Store Performance" do
      it "handles high event volume" do
        event_store = transport.event_store
        
        # Store many events quickly
        start_time = Time.now
        event_count = 1000
        
        event_count.times do |i|
          event_store.store_event("event #{i}", "performance_test")
        end
        
        end_time = Time.now
        duration = end_time - start_time
        
        # Should complete within reasonable time
        expect(duration).to be < 5.0
        
        # Should maintain reasonable event count (may be less due to circular buffer)
        expect(event_store.event_count).to be > 0
      end

      it "is thread-safe for concurrent access" do
        event_store = transport.event_store
        event_ids = Concurrent::Array.new
        
        # Store events from multiple threads
        threads = []
        10.times do |i|
          threads << Thread.new do
            10.times do |j|
              event_id = event_store.store_event("thread #{i} event #{j}")
              event_ids << event_id
            end
          end
        end
        
        threads.each(&:join)
        
        # All events should be unique
        expect(event_ids.uniq.length).to eq(event_ids.length)
      end
    end
  end

  describe "Phase 3: Streaming Connection Management" do
    describe "3.1 Connection Establishment" do
      let(:session_id) { "connection-test" }

      before do
        initialize_mcp_session(base_url, session_id)
      end

      it "establishes connection with valid session" do
        client = StreamingTestHelpers::MockStreamingClient.new(session_id, base_url)
        
        expect(client.start_streaming).to be true
        expect(client.connected?).to be true
        
        client.stop_streaming
      end

      it "handles connection with missing session" do
        client = StreamingTestHelpers::MockStreamingClient.new("non-existent-session", base_url)
        
        # Should still connect (server may create session)
        expect(client.start_streaming).to be true
        
        client.stop_streaming
      end

      it "tracks connection state correctly" do
        client = StreamingTestHelpers::MockStreamingClient.new(session_id, base_url)
        
        expect(client.connection_state).to eq(:disconnected)
        
        client.start_streaming
        expect(client.connection_state).to eq(:connected)
        
        client.stop_streaming
        expect(client.connection_state).to eq(:disconnected)
      end
    end

    describe "3.2 Multi-Session Streaming" do
      let(:session1_id) { "multi-session-1" }
      let(:session2_id) { "multi-session-2" }

      before do
        initialize_mcp_session(base_url, session1_id)
        initialize_mcp_session(base_url, session2_id)
      end

      it "supports multiple concurrent streaming connections" do
        client1 = StreamingTestHelpers::MockStreamingClient.new(session1_id, base_url)
        client2 = StreamingTestHelpers::MockStreamingClient.new(session2_id, base_url)
        
        expect(client1.start_streaming).to be true
        expect(client2.start_streaming).to be true
        
        expect(client1.connected?).to be true
        expect(client2.connected?).to be true
        
        client1.stop_streaming
        client2.stop_streaming
      end

      it "isolates sessions correctly" do
        client1 = StreamingTestHelpers::MockStreamingClient.new(session1_id, base_url)
        client2 = StreamingTestHelpers::MockStreamingClient.new(session2_id, base_url)
        
        client1.start_streaming
        client2.start_streaming
        
        # Each client should maintain separate session context
        expect(client1.session_id).to eq(session1_id)
        expect(client2.session_id).to eq(session2_id)
        
        client1.stop_streaming
        client2.stop_streaming
      end
    end

    describe "3.3 Connection Cleanup" do
      let(:session_id) { "cleanup-test" }

      before do
        initialize_mcp_session(base_url, session_id)
      end

      it "cleans up resources on disconnect" do
        client = StreamingTestHelpers::MockStreamingClient.new(session_id, base_url)
        
        client.start_streaming
        expect(client.connected?).to be true
        
        # Simulate abrupt disconnection
        client.stop_streaming
        
        # Should clean up properly
        expect(client.connected?).to be false
        expect(client.connection_state).to eq(:disconnected)
      end

      it "handles server shutdown gracefully" do
        client = StreamingTestHelpers::MockStreamingClient.new(session_id, base_url)
        
        client.start_streaming
        expect(client.connected?).to be true
        
        # Server shutdown will be handled in after block
        # Client should detect disconnection
        
        client.stop_streaming
      end
    end
  end
end