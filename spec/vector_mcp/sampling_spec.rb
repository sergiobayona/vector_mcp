# frozen_string_literal: true

require "spec_helper"
require "vector_mcp"
require "stringio"

RSpec.describe "VectorMCP Sampling Feature", type: :integration do
  let(:server_name) { "TestSamplingServer" }
  let(:server_version) { "0.1.0" }
  let(:server) { VectorMCP::Server.new(name: server_name, version: server_version, log_level: Logger::WARN) }
  let(:stdio_transport) { VectorMCP::Transport::Stdio.new(server) }
  let(:session) { VectorMCP::Session.new(server, stdio_transport, id: "test_session_stdio") }

  let(:original_stdin) { $stdin }
  let(:original_stdout) { $stdout }
  let(:mock_stdin) { StringIO.new }
  let(:mock_stdout) { StringIO.new }

  before do
    # Initialize session for most tests
    # Simulate client sending 'initialize' and server responding, then client sending 'initialized'
    # This is a simplified handshake for testing purposes.
    allow(server).to receive(:protocol_version).and_return("2024-11-05") # Match the example
    allow(server).to receive(:server_info).and_return({ name: server_name, version: server_version })
    allow(server).to receive(:server_capabilities).and_return({ sampling: {} })

    # Simulate the server correctly processing the initialize request via session
    # The actual initialize! method is complex, so we'll just ensure the state is set.
    session.instance_variable_set(:@initialized_state, :succeeded)
    session.instance_variable_set(:@client_info, { name: "TestClient", version: "1.0" })
    session.instance_variable_set(:@client_capabilities, {})

    $stdin = mock_stdin
    $stdout = mock_stdout
  end

  after do
    $stdin = original_stdin
    $stdout = original_stdout
  end

  describe "Session#sample via StdioTransport" do
    context "when client provides a valid text response" do
      let(:sample_request_params) do
        {
          messages: [{ role: "user", content: { type: "text", text: "Hello MCP!" } }],
          max_tokens: 50
        }
      end

      let(:client_response_payload) do
        {
          jsonrpc: "2.0",
          id: nil, # This will be set by the test based on what stdio_transport sends
          result: {
            model: "test-model",
            role: "assistant",
            content: {
              type: "text",
              text: "Hello Server!"
            }
          }
        }
      end

      it "sends a sampling/createMessage request and returns a Sampling::Result" do
        # Configure mock_stdin to provide the response when read
        # We need to know the request_id that stdio_transport will generate.
        # For this test, we'll predict it or inspect it.

        # Start the transport in a separate thread so it can process our mock_stdin
        transport_thread = Thread.new { stdio_transport.run }
        # Give the transport a moment to start listening (crude, but often needed for IO tests)
        sleep 0.01

        # The actual call we are testing
        sampling_result = nil

        # This thread will perform the sample call and then we join it.
        # This is to avoid the main test thread blocking indefinitely if stdio_transport.run blocks it.
        sample_call_thread = Thread.new do
          # Predict or capture the request_id for the response
          # For simplicity, let's assume the first generated ID format.
          # A more robust test might spy on SecureRandom or the ID generator.
          expected_request_id = stdio_transport.instance_variable_get(:@request_id_generator).peek

          mock_stdin.string = client_response_payload.merge(id: expected_request_id).to_json + "\n"
          mock_stdin.rewind # Rewind after writing

          sampling_result = session.sample(sample_request_params, timeout: 5) # Use a timeout
        end

        sample_call_thread.join(7) # Join with a slightly longer timeout for the call itself

        # Stop the transport
        stdio_transport.stop
        transport_thread.join(1) # Ensure transport thread exits

        # Verify sampling_result
        expect(sampling_result).to be_a(VectorMCP::Sampling::Result)
        expect(sampling_result.model).to eq("test-model")
        expect(sampling_result.role).to eq("assistant")
        expect(sampling_result.text?).to be true
        expect(sampling_result.text_content).to eq("Hello Server!")

        # Verify what was sent to $stdout
        mock_stdout.rewind
        sent_json_string = mock_stdout.read.lines.map(&:strip).reject(&:empty?).first
        expect(sent_json_string).not_to be_nil

        sent_request = JSON.parse(sent_json_string)
        expect(sent_request["method"]).to eq("sampling/createMessage")
        expect(sent_request["params"]["messages"][0]["content"]["text"]).to eq("Hello MCP!")
        expect(sent_request["params"]["maxTokens"]).to eq(50)
        expect(sent_request["id"]).to be_a(String) # Check an ID was present
      end
    end

    context "when client request times out" do
      let(:sample_request_params) do
        {
          messages: [{ role: "user", content: { type: "text", text: "Will this time out?" } }],
          max_tokens: 10
        }
      end

      it "raises a SamplingTimeoutError" do
        # Don't provide any input to mock_stdin, so it will time out
        mock_stdin.string = "" # Empty input
        mock_stdin.rewind

        transport_thread = Thread.new { stdio_transport.run }
        sleep 0.01

        expect do
          session.sample(sample_request_params, timeout: 0.1) # Very short timeout
        end.to raise_error(VectorMCP::SamplingTimeoutError, /Timeout waiting for client response/)

        stdio_transport.stop
        transport_thread.join(1)
      end
    end

    context "when client returns an error" do
      let(:sample_request_params) do
        {
          messages: [{ role: "user", content: { type: "text", text: "Trigger error" } }]
        }
      end
      let(:client_error_response_payload) do
        {
          jsonrpc: "2.0",
          id: nil, # To be set based on outgoing request ID
          error: {
            code: -32_000,
            message: "Client-side sampling failure",
            data: { reason: "Intentional test error" }
          }
        }
      end

      it "raises a SamplingError" do
        transport_thread = Thread.new { stdio_transport.run }
        sleep 0.01

        sample_call_thread = Thread.new do
          expected_request_id = stdio_transport.instance_variable_get(:@request_id_generator).peek
          mock_stdin.string = client_error_response_payload.merge(id: expected_request_id).to_json + "\n"
          mock_stdin.rewind

          expect do
            session.sample(sample_request_params, timeout: 1)
          end.to raise_error(VectorMCP::SamplingError, /Client returned an error.*-32000.*Client-side sampling failure/)
        end

        sample_call_thread.join(2)

        stdio_transport.stop
        transport_thread.join(1)
      end
    end

    context "when session is not initialized" do
      it "raises an InitializationError" do
        # Override the global initialized state for this specific test
        session.instance_variable_set(:@initialized_state, :pending)
        expect do
          session.sample({ messages: [{ role: "user", content: { type: "text", text: "Test" } }] })
        end.to raise_error(VectorMCP::InitializationError, /session not initialized/)
      end
    end

    # TODO: Add tests for invalid Sampling::Request params (e.g. missing messages)
    # TODO: Add tests for malformed client response (e.g. missing 'model' in result)
  end
end
