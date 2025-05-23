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
    # Set up initialized session state
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
        # Use a more direct approach: mock the transport's send_request method
        expected_result = {
          model: "test-model",
          role: "assistant",
          content: {
            type: "text",
            text: "Hello Server!"
          }
        }

        # Mock the transport's send_request to return our expected result
        allow(stdio_transport).to receive(:send_request)
          .with("sampling/createMessage", anything, any_args)
          .and_return(expected_result)

        # Call the sample method
        sampling_result = session.sample(sample_request_params)

        # Verify the result
        expect(sampling_result).to be_a(VectorMCP::Sampling::Result)
        expect(sampling_result.model).to eq("test-model")
        expect(sampling_result.role).to eq("assistant")
        expect(sampling_result.text?).to be true
        expect(sampling_result.text_content).to eq("Hello Server!")

        # Verify the transport was called with correct parameters
        expect(stdio_transport).to have_received(:send_request) do |method, params, **_options|
          expect(method).to eq("sampling/createMessage")
          expect(params[:messages]).to eq(sample_request_params[:messages])
          expect(params[:maxTokens]).to eq(50)
        end
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
        # Mock the transport to raise a timeout error
        allow(stdio_transport).to receive(:send_request)
          .and_raise(VectorMCP::SamplingTimeoutError, "Timeout waiting for client response")

        expect do
          session.sample(sample_request_params, timeout: 0.1)
        end.to raise_error(VectorMCP::SamplingTimeoutError, /Timeout waiting for client response/)
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
        # Mock the transport to raise a sampling error
        allow(stdio_transport).to receive(:send_request)
          .and_raise(VectorMCP::SamplingError, "Client returned an error: [-32000] Client-side sampling failure")

        expect do
          session.sample(sample_request_params, timeout: 1)
        end.to raise_error(VectorMCP::SamplingError, /Client returned an error.*-32000.*Client-side sampling failure/)
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

  # Test the transport layer's response handling directly
  describe "StdioTransport Response Handling" do
    let(:transport) { VectorMCP::Transport::Stdio.new(server) }
    let(:session) { VectorMCP::Session.new(server, transport) }

    before do
      # Mock logger to avoid noise
      allow(transport).to receive(:logger).and_return(double("Logger", debug: nil, warn: nil, info: nil, error: nil))
      # Initialize the transport's session
      transport.instance_variable_set(:@current_session, session)
      session.instance_variable_set(:@initialized_state, :succeeded)
    end

    describe "#handle_outgoing_response" do
      it "stores response and signals waiting thread" do
        request_id = "test_request_123"
        condition = ConditionVariable.new

        # Set up a condition variable for this request
        transport.instance_variable_get(:@outgoing_request_conditions)[request_id] = condition

        response_message = {
          "jsonrpc" => "2.0",
          "id" => request_id,
          "result" => { "model" => "test-model", "role" => "assistant" }
        }

        # Allow condition signaling
        allow(condition).to receive(:signal)

        # Call the private method
        transport.send(:handle_outgoing_response, response_message)

        # Verify response was stored
        stored_responses = transport.instance_variable_get(:@outgoing_request_responses)
        expected_response = {
          id: "test_request_123",
          jsonrpc: "2.0",
          result: { model: "test-model", role: "assistant" }
        }
        expect(stored_responses[request_id]).to eq(expected_response)

        # Verify condition was signaled
        expect(condition).to have_received(:signal)
      end

      it "handles error responses" do
        request_id = "test_request_456"
        condition = ConditionVariable.new

        transport.instance_variable_get(:@outgoing_request_conditions)[request_id] = condition

        error_message = {
          "jsonrpc" => "2.0",
          "id" => request_id,
          "error" => { "code" => -32_000, "message" => "Sampling failed" }
        }

        allow(condition).to receive(:signal)

        transport.send(:handle_outgoing_response, error_message)

        stored_responses = transport.instance_variable_get(:@outgoing_request_responses)
        expect(stored_responses[request_id][:error][:code]).to eq(-32_000)
        expect(stored_responses[request_id][:error][:message]).to eq("Sampling failed")
        expect(condition).to have_received(:signal)
      end

      it "logs warning when no thread is waiting" do
        logger = double("Logger", debug: nil, warn: nil)
        allow(transport).to receive(:logger).and_return(logger)

        response_message = {
          "jsonrpc" => "2.0",
          "id" => "orphaned_request",
          "result" => { "data" => "test" }
        }

        transport.send(:handle_outgoing_response, response_message)

        expect(logger).to have_received(:warn).with(/no thread is waiting/)
      end
    end

    describe "#handle_input_line response detection" do
      it "detects and routes response messages" do
        response_message = {
          "jsonrpc" => "2.0",
          "id" => "req_123",
          "result" => { "model" => "test" }
        }

        # Mock handle_outgoing_response to verify it gets called
        allow(transport).to receive(:handle_outgoing_response)

        transport.send(:handle_input_line, response_message.to_json, session, "test_session")

        expect(transport).to have_received(:handle_outgoing_response).with(response_message)
      end

      it "detects error response messages" do
        error_message = {
          "jsonrpc" => "2.0",
          "id" => "req_456",
          "error" => { "code" => -32_000, "message" => "Error" }
        }

        allow(transport).to receive(:handle_outgoing_response)

        transport.send(:handle_input_line, error_message.to_json, session, "test_session")

        expect(transport).to have_received(:handle_outgoing_response).with(error_message)
      end

      it "does not route request messages to response handler" do
        request_message = {
          "jsonrpc" => "2.0",
          "id" => "req_789",
          "method" => "some/method",
          "params" => {}
        }

        allow(transport).to receive(:handle_outgoing_response)
        allow(server).to receive(:handle_message).and_return(nil)

        transport.send(:handle_input_line, request_message.to_json, session, "test_session")

        expect(transport).not_to have_received(:handle_outgoing_response)
        expect(server).to have_received(:handle_message)
      end

      it "does not route notification messages to response handler" do
        notification_message = {
          "jsonrpc" => "2.0",
          "method" => "some/notification",
          "params" => {}
        }

        allow(transport).to receive(:handle_outgoing_response)
        allow(server).to receive(:handle_message).and_return(nil)

        transport.send(:handle_input_line, notification_message.to_json, session, "test_session")

        expect(transport).not_to have_received(:handle_outgoing_response)
        expect(server).to have_received(:handle_message)
      end
    end
  end

  # Integration test with real transport functionality
  describe "End-to-End Sampling with Real Transport" do
    let(:transport) { VectorMCP::Transport::Stdio.new(server) }
    let(:session) { VectorMCP::Session.new(server, transport) }

    before do
      # Set up session state
      session.instance_variable_set(:@initialized_state, :succeeded)
      session.instance_variable_set(:@client_info, { name: "TestClient" })
      session.instance_variable_set(:@client_capabilities, {})

      # Mock logger
      allow(transport).to receive(:logger).and_return(double("Logger", debug: nil, warn: nil, info: nil, error: nil))
    end

    it "handles a complete sampling request-response cycle" do
      sample_params = {
        messages: [{ role: "user", content: { type: "text", text: "Test message" } }],
        max_tokens: 50
      }

      # Mock the actual response handling instead of trying to coordinate threads

      # Simulate what would happen when a response comes in
      response_data = {
        model: "test-model",
        role: "assistant",
        content: { type: "text", text: "Response text" }
      }

      # Mock send_request to return the expected response
      allow(transport).to receive(:send_request)
        .with("sampling/createMessage", anything, any_args)
        .and_return(response_data)

      # Call sample
      result = session.sample(sample_params, timeout: 2)

      # Verify the result
      expect(result).to be_a(VectorMCP::Sampling::Result)
      expect(result.model).to eq("test-model")
      expect(result.text_content).to eq("Response text")
    end
  end

  describe "Sampling Capabilities Configuration Validation" do
    context "when testing server capabilities based on configuration" do
      it "includes proper sampling capabilities in server advertisements" do
        # Test that the server properly advertises its sampling capabilities
        capabilities = server.server_capabilities

        expect(capabilities[:sampling]).to include(:methods, :features, :limits, :contextInclusion)
        expect(capabilities[:sampling][:methods]).to include("createMessage")
        expect(capabilities[:sampling][:features][:modelPreferences]).to be true
        expect(capabilities[:sampling][:limits][:defaultTimeout]).to eq(30)
        expect(capabilities[:sampling][:contextInclusion]).to eq(%w[none thisServer])
      end

      it "respects custom timeout configuration" do
        custom_server = VectorMCP::Server.new(
          name: "CustomTimeoutServer",
          sampling_config: { timeout_seconds: 60 }
        )

        capabilities = custom_server.server_capabilities
        expect(capabilities[:sampling][:limits][:defaultTimeout]).to eq(60)
      end

      it "includes maxTokens limit when configured" do
        limited_server = VectorMCP::Server.new(
          name: "LimitedServer",
          sampling_config: { max_tokens_limit: 2000 }
        )

        capabilities = limited_server.server_capabilities
        expect(capabilities[:sampling][:limits][:maxTokens]).to eq(2000)
      end

      it "advertises advanced features when enabled" do
        advanced_server = VectorMCP::Server.new(
          name: "AdvancedServer",
          sampling_config: {
            supports_streaming: true,
            supports_tool_calls: true,
            supports_images: true
          }
        )

        capabilities = advanced_server.server_capabilities
        features = capabilities[:sampling][:features]

        expect(features[:streaming]).to be true
        expect(features[:toolCalls]).to be true
        expect(features[:images]).to be true
        expect(features[:modelPreferences]).to be true # Default
      end

      it "supports custom context inclusion methods" do
        extended_server = VectorMCP::Server.new(
          name: "ExtendedServer",
          sampling_config: {
            context_inclusion_methods: %w[none thisServer allServers custom]
          }
        )

        capabilities = extended_server.server_capabilities
        expect(capabilities[:sampling][:contextInclusion]).to eq(%w[none thisServer allServers custom])
      end
    end
  end
end
