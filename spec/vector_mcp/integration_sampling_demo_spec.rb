# frozen_string_literal: true

require "spec_helper"
require "vector_mcp"
require "stringio"

RSpec.describe "Sampling Integration Demo", type: :integration do
  describe "Real Stdio Transport Sampling" do
    let(:server) { VectorMCP::Server.new(name: "SamplingDemo", version: "1.0.0") }
    let(:transport) { VectorMCP::Transport::Stdio.new(server) }
    let(:session) { VectorMCP::Session.new(server, transport) }

    before do
      # Initialize session
      session.instance_variable_set(:@initialized_state, :succeeded)
      session.instance_variable_set(:@client_info, { name: "TestClient" })
      session.instance_variable_set(:@client_capabilities, {})
    end

    it "demonstrates working request-response cycle" do
      # Use a simpler approach - directly test send_request
      expected_response = {
        model: "demo-model",
        role: "assistant",
        content: {
          type: "text",
          text: "2+2 equals 4"
        }
      }

      # Mock the actual request sending to return our expected response
      allow(transport).to receive(:send_request)
        .with("sampling/createMessage", anything, any_args)
        .and_return(expected_response)

      # Execute sampling
      result = session.sample({
                                messages: [{
                                  role: "user",
                                  content: { type: "text", text: "What is 2+2?" }
                                }],
                                max_tokens: 10
                              })

      # Verify success
      expect(result).to be_a(VectorMCP::Sampling::Result)
      expect(result.model).to eq("demo-model")
      expect(result.role).to eq("assistant")
      expect(result.text_content).to eq("2+2 equals 4")

      # Verify the correct request was made
      expect(transport).to have_received(:send_request) do |method, params, **_options|
        expect(method).to eq("sampling/createMessage")
        expect(params[:messages][0][:content][:text]).to eq("What is 2+2?")
        expect(params[:maxTokens]).to eq(10)
      end
    end

    it "demonstrates error response handling" do
      # Mock the transport to raise a sampling error
      allow(transport).to receive(:send_request)
        .with("sampling/createMessage", anything, any_args)
        .and_raise(VectorMCP::SamplingError, "Client returned an error for 'sampling/createMessage' request (ID: test_123): [-32001] Content policy violation")

      # Execute sampling and expect error
      expect do
        session.sample({
                         messages: [{
                           role: "user",
                           content: { type: "text", text: "Generate inappropriate content" }
                         }],
                         max_tokens: 50
                       })
      end.to raise_error(VectorMCP::SamplingError) do |error|
        expect(error.message).to include("Content policy violation")
        expect(error.message).to include("-32001")
      end

      # Verify the correct request was attempted
      expect(transport).to have_received(:send_request) do |method, params, **_options|
        expect(method).to eq("sampling/createMessage")
        expect(params[:messages][0][:content][:text]).to eq("Generate inappropriate content")
        expect(params[:maxTokens]).to eq(50)
      end
    end

    it "verifies request format matches MCP specification" do
      # Mock the response to avoid timeout
      allow(transport).to receive(:send_request).and_return({
                                                              model: "test-model",
                                                              role: "assistant",
                                                              content: { type: "text", text: "Response" }
                                                            })

      # Execute sampling
      session.sample({
                       messages: [{
                         role: "user",
                         content: { type: "text", text: "Hello" }
                       }],
                       max_tokens: 25,
                       temperature: 0.7,
                       system_prompt: "You are a helpful assistant",
                       include_context: "thisServer"
                     })

      # Verify the request parameters are correctly formatted
      expect(transport).to have_received(:send_request) do |method, params, **_options|
        expect(method).to eq("sampling/createMessage")

        # Verify all the MCP specification fields are properly transformed
        expect(params).to include(
          messages: [{
            role: "user",
            content: { type: "text", text: "Hello" }
          }],
          maxTokens: 25,
          temperature: 0.7,
          systemPrompt: "You are a helpful assistant",
          includeContext: "thisServer"
        )
      end
    end
  end
end
