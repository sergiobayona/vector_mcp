# frozen_string_literal: true

require "spec_helper"
require "vector_mcp"

RSpec.describe "VectorMCP Sampling Feature", type: :integration do
  let(:server_name) { "TestSamplingServer" }
  let(:server_version) { "0.1.0" }
  let(:server) { VectorMCP::Server.new(name: server_name, version: server_version, log_level: Logger::WARN) }
  let(:mock_transport) { double("transport", send_request: nil) }
  let(:session) { VectorMCP::Session.new(server, mock_transport, id: "test_session_sampling") }

  before do
    # Set up initialized session state
    session.instance_variable_set(:@initialized_state, :succeeded)
    session.instance_variable_set(:@client_info, { name: "TestClient", version: "1.0" })
    session.instance_variable_set(:@client_capabilities, {})
  end

  describe "Session#sample" do
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
          id: nil, # This will be set by the test based on what mock_transport sends
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
        allow(mock_transport).to receive(:send_request)
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
        expect(mock_transport).to have_received(:send_request) do |method, params, **_options|
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
        allow(mock_transport).to receive(:send_request)
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
        allow(mock_transport).to receive(:send_request)
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
