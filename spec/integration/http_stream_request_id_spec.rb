# frozen_string_literal: true

require "spec_helper"
require "vector_mcp/transport/http_stream"
require "vector_mcp/server"
require "concurrent"
require_relative "../support/streaming_test_helpers"
require_relative "../support/http_stream_integration_helpers"

RSpec.describe "HttpStream Request ID Generation Integration", type: :integration do
  include HttpStreamIntegrationHelpers

  let(:test_port) { find_available_port }
  let(:base_url) { "http://localhost:#{test_port}" }
  let(:session_id) { "request-id-test-#{SecureRandom.hex(4)}" }

  let(:server) do
    VectorMCP::Server.new(
      name: "Request ID Test Server",
      version: "1.0.0",
      log_level: Logger::ERROR
    )
  end

  let(:transport) { VectorMCP::Transport::HttpStream.new(server, port: test_port, host: "localhost") }

  before(:each) do
    # Register a tool that triggers server-initiated sampling
    server.register_tool(
      name: "id_test_tool",
      description: "Tool that tests request ID generation",
      input_schema: {
        type: "object",
        properties: {
          message: { type: "string" }
        },
        required: ["message"]
      }
    ) do |args, session|
      # Use sampling to test request ID generation
      result = session.sample({
                                messages: [
                                  {
                                    role: "user",
                                    content: {
                                      type: "text",
                                      text: args["message"]
                                    }
                                  }
                                ],
                                system_prompt: "Echo the message back.",
                                max_tokens: 50
                              })

      {
        message: args["message"],
        sampled_response: result.content,
        request_processed: true
      }
    end

    # Start the server
    @server_thread = Thread.new do
      transport.run
    rescue StandardError
      # Server stopped, expected during cleanup
    end

    # Wait for server to start
    wait_for_server_start(base_url)
  end

  after(:each) do
    transport.stop
    @server_thread&.join(2)
  end

  describe "Request ID Generation in Real Scenarios" do
    describe "Single Session Multiple Requests" do
      let(:mock_client) { StreamingTestHelpers::MockStreamingClient.new(session_id, base_url) }

      before do
        initialize_mcp_session(base_url, session_id)
        mock_client.set_sampling_response("sampling/createMessage", "Test response")
        mock_client.start_streaming
      end

      after do
        mock_client.stop_streaming
      end

      it "generates unique request IDs for each sampling call" do
        request_ids = []

        # Capture request IDs from sampling calls
        mock_client.on_method("sampling/createMessage") do |event|
          request_ids << event[:data]["id"]
        end

        # Make multiple tool calls that trigger sampling
        3.times do |i|
          call_tool(base_url, session_id, "id_test_tool", {
                      message: "Test message #{i}"
                    })
          sleep(0.1) # Small delay to ensure proper ordering
        end

        # Wait for all sampling calls to be captured
        sleep(1)

        # Verify unique IDs generated
        expect(request_ids.length).to eq(3)
        expect(request_ids.uniq.length).to eq(3)

        # Verify all IDs follow the expected format
        request_ids.each do |id|
          expect(id).to match(/\Avecmcp_http_\d+_[a-f0-9]{8}_\d+\z/)
          expect(id).to include(Process.pid.to_s)
        end

        # Verify incrementing counter pattern
        counters = request_ids.map { |id| id.split("_").last.to_i }
        expect(counters.sort).to eq(counters) # Should be in ascending order
      end

      it "maintains consistent base across multiple requests" do
        request_ids = []

        mock_client.on_method("sampling/createMessage") do |event|
          request_ids << event[:data]["id"]
        end

        # Make several requests
        5.times do |i|
          call_tool(base_url, session_id, "id_test_tool", {
                      message: "Base test #{i}"
                    })
          sleep(0.05)
        end

        sleep(1)

        # Extract base pattern (everything except the counter)
        bases = request_ids.map { |id| id.gsub(/_\d+\z/, "") }
        
        # All should have the same base
        expect(bases.uniq.length).to eq(1)
        
        # Base should follow expected format
        base = bases.first
        expect(base).to match(/\Avecmcp_http_\d+_[a-f0-9]{8}\z/)
      end
    end

    describe "Multiple Sessions Concurrent Requests" do
      let(:session1_id) { "id-test-session-1" }
      let(:session2_id) { "id-test-session-2" }
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

      it "generates unique IDs across multiple concurrent sessions" do
        all_request_ids = []
        session1_ids = []
        session2_ids = []

        # Capture IDs from both sessions
        client1.on_method("sampling/createMessage") do |event|
          id = event[:data]["id"]
          session1_ids << id
          all_request_ids << id
        end

        client2.on_method("sampling/createMessage") do |event|
          id = event[:data]["id"]
          session2_ids << id
          all_request_ids << id
        end

        # Make concurrent requests from both sessions
        threads = []
        
        threads << Thread.new do
          3.times do |i|
            call_tool(base_url, session1_id, "id_test_tool", {
                        message: "Session 1 message #{i}"
                      })
            sleep(0.02)
          end
        end

        threads << Thread.new do
          3.times do |i|
            call_tool(base_url, session2_id, "id_test_tool", {
                        message: "Session 2 message #{i}"
                      })
            sleep(0.02)
          end
        end

        threads.each(&:join)
        sleep(1.5) # Wait for all sampling calls to complete

        # All IDs should be unique across sessions
        expect(all_request_ids.length).to eq(6)
        expect(all_request_ids.uniq.length).to eq(6)

        # Each session should have received requests
        expect(session1_ids.length).to eq(3)
        expect(session2_ids.length).to eq(3)

        # All IDs should follow the format
        all_request_ids.each do |id|
          expect(id).to match(/\Avecmcp_http_\d+_[a-f0-9]{8}_\d+\z/)
        end

        # No ID collisions between sessions
        expect((session1_ids & session2_ids).empty?).to be true
      end
    end

    describe "High Load Request ID Generation" do
      let(:mock_client) { StreamingTestHelpers::MockStreamingClient.new(session_id, base_url) }

      before do
        initialize_mcp_session(base_url, session_id)
        mock_client.set_sampling_response("sampling/createMessage", "Load test response")
        mock_client.start_streaming
      end

      after do
        mock_client.stop_streaming
      end

      it "handles high-frequency request ID generation without collisions" do
        # Test request ID generation directly to avoid sampling complexity
        request_ids = Concurrent::Array.new

        # Generate many request IDs concurrently to test thread safety
        threads = []
        requests_per_thread = 25
        thread_count = 4

        thread_count.times do |thread_num|
          threads << Thread.new do
            requests_per_thread.times do |req_num|
              # Access the transport directly to test ID generation
              id = transport.send(:generate_request_id)
              request_ids << id
              sleep(0.001) # Simulate rapid generation
            end
          end
        end

        threads.each(&:join)

        total_expected = requests_per_thread * thread_count
        
        # Verify all request IDs are unique (no collisions)
        expect(request_ids.length).to eq(total_expected)
        expect(request_ids.to_a.uniq.length).to eq(total_expected)

        # Verify format consistency under concurrent load
        request_ids.each do |id|
          expect(id).to match(/\Avecmcp_http_\d+_[a-f0-9]{8}_\d+\z/)
        end
        
        # Verify counter incrementing works correctly under load
        counters = request_ids.map { |id| id.split("_").last.to_i }.sort
        expect(counters.first).to be >= 1
        expect(counters.last).to be <= total_expected
        expect(counters).to eq(counters.uniq.sort) # All unique, ascending
      end
    end

    describe "Request ID Persistence and Recovery" do
      let(:mock_client) { StreamingTestHelpers::MockStreamingClient.new(session_id, base_url) }

      before do
        initialize_mcp_session(base_url, session_id)
        mock_client.set_sampling_response("sampling/createMessage", "Persistence test")
        mock_client.start_streaming
      end

      after do
        mock_client.stop_streaming
      end

      it "maintains ID generation state across multiple tool calls" do
        first_batch_ids = []
        second_batch_ids = []

        # First batch of requests
        mock_client.on_method("sampling/createMessage") do |event|
          first_batch_ids << event[:data]["id"]
        end

        3.times do |i|
          call_tool(base_url, session_id, "id_test_tool", {
                      message: "First batch #{i}"
                    })
        end

        sleep(1)

        # Clear the handler and capture second batch
        mock_client.clear_method_handlers
        mock_client.on_method("sampling/createMessage") do |event|
          second_batch_ids << event[:data]["id"]
        end

        3.times do |i|
          call_tool(base_url, session_id, "id_test_tool", {
                      message: "Second batch #{i}"
                    })
        end

        sleep(1)

        # Verify counter continued incrementing
        all_ids = first_batch_ids + second_batch_ids
        counters = all_ids.map { |id| id.split("_").last.to_i }
        
        expect(counters).to eq(counters.sort) # Should be in ascending order
        expect(counters.uniq.length).to eq(6) # All unique counters
        
        # Verify no gaps in the sequence (consecutive incrementing)
        expect(counters.max - counters.min).to eq(5) # Range should be exactly 5 (6 numbers - 1)
      end
    end
  end

  describe "Request ID Regression Prevention" do
    it "prevents fiber-related errors during ID generation" do
      # This test ensures we don't regress back to using Enumerator/Fiber
      # which caused the original "fiber called across threads" error
      
      expect {
        # Create a new transport instance
        new_transport = VectorMCP::Transport::HttpStream.new(server, port: find_available_port)
        
        # Generate IDs from multiple threads simultaneously
        threads = []
        5.times do
          threads << Thread.new do
            10.times do
              new_transport.send(:generate_request_id)
            end
          end
        end
        
        threads.each(&:join)
      }.not_to raise_error
    end

    it "ensures thread-safe counter operations" do
      # Verify that the AtomicFixnum counter works correctly under concurrent access
      new_transport = VectorMCP::Transport::HttpStream.new(server, port: find_available_port)
      
      ids = Concurrent::Array.new
      
      threads = []
      10.times do
        threads << Thread.new do
          50.times do
            ids << new_transport.send(:generate_request_id)
          end
        end
      end
      
      threads.each(&:join)
      
      # All 500 IDs should be unique
      expect(ids.length).to eq(500)
      expect(ids.to_a.uniq.length).to eq(500)
      
      # Extract counters and verify they form a complete sequence
      counters = ids.map { |id| id.split("_").last.to_i }.sort
      expect(counters.first).to eq(1) # First counter value
      expect(counters.last).to eq(500) # Last counter value  
      expect(counters).to eq((1..500).to_a) # Complete sequence with no gaps
    end
  end
end