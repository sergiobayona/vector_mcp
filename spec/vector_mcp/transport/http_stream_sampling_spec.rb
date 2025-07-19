# frozen_string_literal: true

require "spec_helper"
require "vector_mcp/transport/http_stream"

RSpec.describe VectorMCP::Transport::HttpStream, "#send_request sampling support" do
  let(:server) { VectorMCP::Server.new("test-server") }
  let(:transport) { described_class.new(server, port: 8080) }
  let(:session_manager) { transport.session_manager }
  let(:stream_handler) { transport.stream_handler }

  describe "#send_request" do
    context "when no streaming session exists" do
      it "raises ArgumentError" do
        expect do
          transport.send_request("sampling/createMessage", { messages: [] })
        end.to raise_error(ArgumentError, /No streaming session available/)
      end
    end

    context "when streaming session exists" do
      let(:session) { session_manager.create_session }
      let(:mock_connection) { double("StreamingConnection", close: nil) }

      before do
        session_manager.set_streaming_connection(session, mock_connection)
      end

      it "sends request to streaming session" do
        expect(stream_handler).to receive(:send_message_to_session).with(
          session,
          hash_including(
            jsonrpc: "2.0",
            method: "sampling/createMessage",
            params: { messages: [] }
          )
        ).and_return(true)

        # Mock the response handling
        allow(transport).to receive(:wait_for_response).and_return({ result: { role: "assistant", content: { type: "text", text: "Hello!" } } })

        result = transport.send_request("sampling/createMessage", { messages: [] })
        expect(result).to eq({ role: "assistant", content: { type: "text", text: "Hello!" } })
      end

      it "handles request failures" do
        expect(stream_handler).to receive(:send_message_to_session).and_return(false)

        expect do
          transport.send_request("sampling/createMessage", { messages: [] })
        end.to raise_error(VectorMCP::SamplingError, /Failed to send request/)
      end

      it "validates method parameter" do
        expect do
          transport.send_request("", { messages: [] })
        end.to raise_error(ArgumentError, /Method cannot be blank/)

        expect do
          transport.send_request(nil, { messages: [] })
        end.to raise_error(ArgumentError, /Method cannot be blank/)
      end
    end
  end

  describe "#send_request_to_session" do
    let(:session) { session_manager.create_session }
    let(:mock_connection) { double("StreamingConnection", close: nil) }

    before do
      session_manager.set_streaming_connection(session, mock_connection)
    end

    it "sends request to specific session" do
      expect(stream_handler).to receive(:send_message_to_session).with(
        session,
        hash_including(
          jsonrpc: "2.0",
          method: "sampling/createMessage",
          params: { messages: [] }
        )
      ).and_return(true)

      # Mock the response handling
      allow(transport).to receive(:wait_for_response).and_return({ result: { role: "assistant", content: { type: "text", text: "Hello!" } } })

      result = transport.send_request_to_session(session.id, "sampling/createMessage", { messages: [] })
      expect(result).to eq({ role: "assistant", content: { type: "text", text: "Hello!" } })
    end

    it "raises error for non-existent session" do
      expect do
        transport.send_request_to_session("non-existent", "sampling/createMessage", { messages: [] })
      end.to raise_error(ArgumentError, /Session not found/)
    end

    it "raises error for session without streaming" do
      non_streaming_session = session_manager.create_session
      expect do
        transport.send_request_to_session(non_streaming_session.id, "sampling/createMessage", { messages: [] })
      end.to raise_error(ArgumentError, /Session must have streaming connection/)
    end
  end

  describe "response handling" do
    let(:session) { session_manager.create_session }
    let(:mock_connection) { double("StreamingConnection", close: nil) }

    before do
      session_manager.set_streaming_connection(session, mock_connection)
    end

    describe "#outgoing_response?" do
      it "identifies response messages" do
        response_msg = { "id" => "req-1", "result" => { "text" => "Hello" } }
        expect(transport.send(:outgoing_response?, response_msg)).to be true

        error_msg = { "id" => "req-2", "error" => { "code" => -1, "message" => "Error" } }
        expect(transport.send(:outgoing_response?, error_msg)).to be true

        request_msg = { "id" => "req-3", "method" => "ping" }
        expect(transport.send(:outgoing_response?, request_msg)).to be false

        notification_msg = { "method" => "notification" }
        expect(transport.send(:outgoing_response?, notification_msg)).to be false
      end
    end

    describe "#handle_outgoing_response" do
      it "stores response and signals waiting threads" do
        request_id = "test-req-1"
        response_msg = { "id" => request_id, "result" => { "text" => "Hello" } }

        # Set up tracking
        transport.send(:setup_request_tracking, request_id)

        # Handle the response
        transport.send(:handle_outgoing_response, response_msg)

        # Verify response was stored
        stored_response = transport.instance_variable_get(:@outgoing_request_responses)[request_id]
        expect(stored_response).to eq({
                                        id: request_id,
                                        result: { text: "Hello" }
                                      })
      end
    end
  end
end
