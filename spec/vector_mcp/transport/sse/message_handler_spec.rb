# frozen_string_literal: true

require "spec_helper"
require "vector_mcp/transport/sse/message_handler"
require "vector_mcp/transport/sse/client_connection"
require "vector_mcp/transport/sse/stream_manager"

RSpec.describe VectorMCP::Transport::SSE::MessageHandler do
  let(:logger) { instance_double(Logger, debug: nil, warn: nil, error: nil, info: nil) }
  let(:mock_server) { instance_double(VectorMCP::Server) }
  let(:mock_session) { instance_double(VectorMCP::Session) }
  let(:client_conn) { instance_double(VectorMCP::Transport::SSE::ClientConnection, session_id: "test-session") }
  let(:message_handler) { described_class.new(mock_server, mock_session, logger) }

  describe "#initialize" do
    it "sets the correct attributes" do
      handler = described_class.new(mock_server, mock_session, logger)
      expect(handler.instance_variable_get(:@server)).to eq(mock_server)
      expect(handler.instance_variable_get(:@session)).to eq(mock_session)
      expect(handler.instance_variable_get(:@logger)).to eq(logger)
    end
  end

  describe "#handle_post_message" do
    let(:rack_env) do
      {
        "REQUEST_METHOD" => "POST",
        "rack.input" => StringIO.new(request_body)
      }
    end

    context "with valid JSON-RPC request" do
      let(:request_body) { '{"jsonrpc":"2.0","id":"123","method":"ping","params":{}}' }
      let(:parsed_message) { { "jsonrpc" => "2.0", "id" => "123", "method" => "ping", "params" => {} } }
      let(:server_response) { { "pong" => true } }

      before do
        allow(mock_server).to receive(:handle_message).and_return(server_response)
        allow(VectorMCP::Transport::SSE::StreamManager).to receive(:enqueue_message).and_return(true)
      end

      it "returns 202 Accepted" do
        status, headers, body = message_handler.handle_post_message(rack_env, client_conn)
        expect(status).to eq(202)
        expect(headers["Content-Type"]).to eq("application/json")
      end

      it "calls server.handle_message with correct parameters" do
        expect(mock_server).to receive(:handle_message).with(parsed_message, mock_session, "test-session")
        message_handler.handle_post_message(rack_env, client_conn)
      end

      it "enqueues success response via StreamManager" do
        expect(VectorMCP::Transport::SSE::StreamManager).to receive(:enqueue_message).with(
          client_conn,
          hash_including(
            jsonrpc: "2.0",
            id: "123",
            result: server_response
          )
        )
        message_handler.handle_post_message(rack_env, client_conn)
      end

      it "includes request ID in response body" do
        _, _, body = message_handler.handle_post_message(rack_env, client_conn)
        response_data = JSON.parse(body.first)
        expect(response_data["id"]).to eq("123")
        expect(response_data["status"]).to eq("accepted")
      end
    end

    context "with valid JSON-RPC notification (no id)" do
      let(:request_body) { '{"jsonrpc":"2.0","method":"notification","params":{}}' }
      let(:parsed_message) { { "jsonrpc" => "2.0", "method" => "notification", "params" => {} } }

      before do
        allow(mock_server).to receive(:handle_message).and_return(nil)
      end

      it "processes the notification" do
        expect(mock_server).to receive(:handle_message).with(parsed_message, mock_session, "test-session")
        message_handler.handle_post_message(rack_env, client_conn)
      end

      it "does not enqueue a response" do
        expect(VectorMCP::Transport::SSE::StreamManager).not_to receive(:enqueue_message)
        message_handler.handle_post_message(rack_env, client_conn)
      end

      it "logs the notification processing" do
        expect(logger).to receive(:debug)
        message_handler.handle_post_message(rack_env, client_conn)
      end

      it "returns 202 Accepted with null id" do
        _, _, body = message_handler.handle_post_message(rack_env, client_conn)
        response_data = JSON.parse(body.first)
        expect(response_data["id"]).to be_nil
        expect(response_data["status"]).to eq("accepted")
      end
    end

    context "with empty request body" do
      let(:request_body) { "" }

      it "returns 400 Bad Request" do
        status, = message_handler.handle_post_message(rack_env, client_conn)
        expect(status).to eq(400)
      end

      it "returns JSON-RPC error response" do
        _, _, body = message_handler.handle_post_message(rack_env, client_conn)
        response_data = JSON.parse(body.first)
        expect(response_data["error"]["code"]).to eq(-32_600)
        expect(response_data["error"]["message"]).to eq("Request body is empty")
      end
    end

    context "with invalid JSON" do
      let(:request_body) { '{"invalid": json}' }

      before do
        allow(VectorMCP::Util).to receive(:extract_id_from_invalid_json).and_return("malformed-123")
        allow(VectorMCP::Transport::SSE::StreamManager).to receive(:enqueue_message).and_return(true)
      end

      it "returns 400 Bad Request" do
        status, = message_handler.handle_post_message(rack_env, client_conn)
        expect(status).to eq(400)
      end

      it "enqueues parse error to client" do
        expect(VectorMCP::Transport::SSE::StreamManager).to receive(:enqueue_message).with(
          client_conn,
          hash_including(
            jsonrpc: "2.0",
            id: "malformed-123",
            error: hash_including(code: -32_700, message: "Parse error")
          )
        )
        message_handler.handle_post_message(rack_env, client_conn)
      end

      it "logs the parse error" do
        expect(logger).to receive(:error)
        message_handler.handle_post_message(rack_env, client_conn)
      end
    end

    context "when server raises ProtocolError" do
      let(:request_body) { '{"jsonrpc":"2.0","id":"456","method":"unknown"}' }
      let(:protocol_error) do
        VectorMCP::MethodNotFoundError.new("Method not found", request_id: "456", details: { method: "unknown" })
      end

      before do
        allow(mock_server).to receive(:handle_message).and_raise(protocol_error)
        allow(VectorMCP::Transport::SSE::StreamManager).to receive(:enqueue_message).and_return(true)
      end

      it "returns appropriate HTTP status" do
        status, = message_handler.handle_post_message(rack_env, client_conn)
        expect(status).to eq(404) # MethodNotFound maps to 404
      end

      it "enqueues error response to client" do
        expect(VectorMCP::Transport::SSE::StreamManager).to receive(:enqueue_message).with(
          client_conn,
          hash_including(
            jsonrpc: "2.0",
            id: "456",
            error: hash_including(
              code: protocol_error.code,
              message: protocol_error.message,
              data: protocol_error.details
            )
          )
        )
        message_handler.handle_post_message(rack_env, client_conn)
      end

      it "logs the protocol error" do
        expect(logger).to receive(:error)
        message_handler.handle_post_message(rack_env, client_conn)
      end
    end

    context "when server raises unexpected StandardError" do
      let(:request_body) { '{"jsonrpc":"2.0","id":"789","method":"crash"}' }
      let(:standard_error) { StandardError.new("Unexpected error") }

      before do
        allow(mock_server).to receive(:handle_message).and_raise(standard_error)
        allow(VectorMCP::Transport::SSE::StreamManager).to receive(:enqueue_message).and_return(true)
      end

      it "returns 500 Internal Server Error" do
        status, = message_handler.handle_post_message(rack_env, client_conn)
        expect(status).to eq(500)
      end

      it "enqueues internal error response to client" do
        expect(VectorMCP::Transport::SSE::StreamManager).to receive(:enqueue_message).with(
          client_conn,
          hash_including(
            jsonrpc: "2.0",
            id: "789",
            error: hash_including(
              code: -32_603,
              message: "Internal server error"
            )
          )
        )
        message_handler.handle_post_message(rack_env, client_conn)
      end

      it "logs the unexpected error with backtrace" do
        expect(logger).to receive(:error)
        message_handler.handle_post_message(rack_env, client_conn)
      end
    end
  end

  describe "private methods" do
    describe "#read_request_body" do
      context "with StringIO input" do
        let(:input) { StringIO.new("test body") }
        let(:env) { { "rack.input" => input } }

        it "reads and rewinds the input" do
          body = message_handler.send(:read_request_body, env)
          expect(body).to eq("test body")
          expect(input.pos).to eq(0) # Should be rewound
        end
      end

      context "with no rack.input" do
        let(:env) { {} }

        it "returns nil" do
          body = message_handler.send(:read_request_body, env)
          expect(body).to be_nil
        end
      end

      context "with input that doesn't support rewind" do
        let(:input) { double("input", read: "test body") }
        let(:env) { { "rack.input" => input } }

        it "reads successfully without rewinding" do
          allow(input).to receive(:respond_to?).with(:rewind).and_return(false)
          expect(input).not_to receive(:rewind)
          body = message_handler.send(:read_request_body, env)
          expect(body).to eq("test body")
        end
      end
    end

    describe "#error_response" do
      it "maps error codes to correct HTTP status codes" do
        # Parse error
        status, = message_handler.send(:error_response, "1", -32_700, "Parse error")
        expect(status).to eq(400)

        # Method not found
        status, = message_handler.send(:error_response, "2", -32_601, "Method not found")
        expect(status).to eq(404)

        # Internal error
        status, = message_handler.send(:error_response, "3", -32_603, "Internal error")
        expect(status).to eq(500)

        # Custom server error
        status, = message_handler.send(:error_response, "4", -32_001, "Custom error")
        expect(status).to eq(404)

        # Unknown error code
        status, = message_handler.send(:error_response, "5", -1000, "Unknown error")
        expect(status).to eq(500)
      end

      it "formats JSON-RPC error response correctly" do
        _, _, body = message_handler.send(:error_response, "test-id", -32_601, "Not found", { extra: "data" })
        response = JSON.parse(body.first)

        expect(response).to eq({
                                 "jsonrpc" => "2.0",
                                 "id" => "test-id",
                                 "error" => {
                                   "code" => -32_601,
                                   "message" => "Not found",
                                   "data" => { "extra" => "data" }
                                 }
                               })
      end

      it "omits data field when not provided" do
        _, _, body = message_handler.send(:error_response, "test-id", -32_601, "Not found")
        response = JSON.parse(body.first)

        expect(response["error"]).not_to have_key("data")
      end
    end

    describe "#success_response" do
      it "returns 202 Accepted with correct body" do
        status, headers, body = message_handler.send(:success_response, "success-123")

        expect(status).to eq(202)
        expect(headers["Content-Type"]).to eq("application/json")

        response = JSON.parse(body.first)
        expect(response).to eq({
                                 "status" => "accepted",
                                 "id" => "success-123"
                               })
      end

      it "handles nil request ID" do
        _, _, body = message_handler.send(:success_response, nil)
        response = JSON.parse(body.first)
        expect(response["id"]).to be_nil
      end
    end
  end
end
