# frozen_string_literal: true

require "spec_helper"
require "vector_mcp/transport/sse/stream_manager"
require "vector_mcp/transport/sse/client_connection"

RSpec.describe VectorMCP::Transport::SSE::StreamManager do
  let(:session_id) { "test-session-456" }
  let(:logger) { instance_double(Logger, debug: nil, warn: nil, error: nil, info: nil) }
  let(:client_conn) { instance_double(VectorMCP::Transport::SSE::ClientConnection, session_id: session_id, closed?: false) }
  let(:endpoint_url) { "/mcp/message?session_id=#{session_id}" }

  describe ".enqueue_message" do
    let(:message) { { jsonrpc: "2.0", method: "test", params: {} } }

    context "with valid client connection" do
      before do
        allow(client_conn).to receive(:enqueue_message).and_return(true)
      end

      it "delegates to client connection" do
        expect(client_conn).to receive(:enqueue_message).with(message)
        result = described_class.enqueue_message(client_conn, message)
        expect(result).to be true
      end
    end

    context "with closed client connection" do
      before do
        allow(client_conn).to receive(:closed?).and_return(true)
      end

      it "returns false" do
        result = described_class.enqueue_message(client_conn, message)
        expect(result).to be false
      end

      it "does not call enqueue_message on client" do
        expect(client_conn).not_to receive(:enqueue_message)
        described_class.enqueue_message(client_conn, message)
      end
    end

    context "with nil client connection" do
      it "returns false" do
        result = described_class.enqueue_message(nil, message)
        expect(result).to be false
      end
    end
  end

  describe ".create_sse_stream" do
    let(:yielder) { [] }
    let(:mock_enumerator) { double("Enumerator") }

    before do
      allow(Enumerator).to receive(:new).and_yield(yielder).and_return(mock_enumerator)
      allow(client_conn).to receive(:close)
    end

    it "returns an Enumerator" do
      result = described_class.create_sse_stream(client_conn, endpoint_url, logger)
      expect(result).to eq(mock_enumerator)
    end

    it "sends initial endpoint event" do
      described_class.create_sse_stream(client_conn, endpoint_url, logger)
      expect(yielder).to include("event: endpoint\ndata: #{endpoint_url}\n\n")
    end

    it "logs the endpoint event" do
      expect(logger).to receive(:debug)
      described_class.create_sse_stream(client_conn, endpoint_url, logger)
    end

    context "when streaming thread encounters error" do
      before do
        allow(Thread).to receive(:new).and_raise(StandardError, "Thread error")
      end

      it "logs the error" do
        expect(logger).to receive(:error).
        described_class.create_sse_stream(client_conn, endpoint_url, logger)
      end

      it "closes the client connection" do
        expect(client_conn).to receive(:close)
        described_class.create_sse_stream(client_conn, endpoint_url, logger)
      end
    end
  end

  describe "SSE event formatting" do
    it "formats events correctly" do
      # Test the private format_sse_event method through public interface
      yielder = []
      allow(Enumerator).to receive(:new).and_yield(yielder)
      allow(client_conn).to receive(:close)
      allow(Thread).to receive(:new) # Prevent actual thread creation

      described_class.create_sse_stream(client_conn, endpoint_url, logger)

      # Check that the endpoint event is properly formatted
      endpoint_event = yielder.first
      expect(endpoint_event).to eq("event: endpoint\ndata: #{endpoint_url}\n\n")
    end
  end

  describe "message streaming thread behavior" do
    let(:messages) { [{ id: 1, method: "test1" }, { id: 2, method: "test2" }] }
    let(:yielder) { [] }
    let(:mock_thread) { double("Thread") }

    before do
      allow(Enumerator).to receive(:new).and_yield(yielder)
      allow(client_conn).to receive(:close)
      allow(client_conn).to receive(:stream_thread=)
    end

    context "with successful message streaming" do
      before do
        call_count = 0
        allow(client_conn).to receive(:dequeue_message) do
          call_count += 1
          case call_count
          when 1 then messages[0]
          when 2 then messages[1]
          else nil # End streaming
          end
        end

        # Mock Thread.new to execute the block immediately for testing
        allow(Thread).to receive(:new) do |&block|
          mock_thread.tap { block.call }
        end
        allow(mock_thread).to receive(:join)
      end

      it "processes all messages" do
        described_class.create_sse_stream(client_conn, endpoint_url, logger)

        # Should have endpoint event plus two message events
        expect(yielder.length).to eq(3)
        expect(yielder[0]).to include("event: endpoint")
        expect(yielder[1]).to include("event: message")
        expect(yielder[1]).to include(messages[0].to_json)
        expect(yielder[2]).to include("event: message")
        expect(yielder[2]).to include(messages[1].to_json)
      end

      it "logs message streaming" do
        expect(logger).to receive(:debug).at_least(:once)
        described_class.create_sse_stream(client_conn, endpoint_url, logger)
      end
    end

    context "when message serialization fails" do
      let(:bad_message) { { circular: nil } }

      before do
        bad_message[:circular] = bad_message # Create circular reference

        call_count = 0
        allow(client_conn).to receive(:dequeue_message) do
          call_count += 1
          call_count == 1 ? bad_message : nil
        end

        allow(Thread).to receive(:new) do |&block|
          mock_thread.tap { block.call }
        end
        allow(mock_thread).to receive(:join)
      end

      it "logs the error and breaks the loop" do
        expect(logger).to receive(:error).
        described_class.create_sse_stream(client_conn, endpoint_url, logger)

        # Should only have the endpoint event, no message events
        expect(yielder.length).to eq(1)
        expect(yielder[0]).to include("event: endpoint")
      end
    end

    context "when dequeue_message returns nil immediately" do
      before do
        allow(client_conn).to receive(:dequeue_message).and_return(nil)
        allow(Thread).to receive(:new) do |&block|
          mock_thread.tap { block.call }
        end
        allow(mock_thread).to receive(:join)
      end

      it "exits the streaming loop cleanly" do
        expect(logger).to receive(:debug).at_least(:once)
        described_class.create_sse_stream(client_conn, endpoint_url, logger)

        # Should only have the endpoint event
        expect(yielder.length).to eq(1)
        expect(yielder[0]).to include("event: endpoint")
      end
    end
  end

  describe "error handling in streaming thread" do
    let(:yielder) { [] }
    let(:mock_thread) { double("Thread") }

    before do
      allow(Enumerator).to receive(:new).and_yield(yielder)
      allow(client_conn).to receive(:close)
      allow(client_conn).to receive(:stream_thread=)
    end

    it "catches and logs fatal errors in streaming thread" do
      allow(Thread).to receive(:new) do |&block|
        mock_thread.tap do
          expect(logger).to receive(:error)
          begin
            block.call
          rescue StandardError
            # Simulate thread error handling
          end
        end
      end
      allow(mock_thread).to receive(:join)

      # Simulate a fatal error in the streaming loop
      allow(client_conn).to receive(:dequeue_message).and_raise(StandardError, "Fatal error")

      described_class.create_sse_stream(client_conn, endpoint_url, logger)
    end
  end

  describe "thread lifecycle management" do
    let(:yielder) { [] }
    let(:real_thread) { Thread.new { sleep(0.01) } }

    before do
      allow(Enumerator).to receive(:new).and_yield(yielder)
      allow(client_conn).to receive(:close)
      allow(client_conn).to receive(:dequeue_message).and_return(nil)
    end

    it "assigns the thread to client connection" do
      expect(client_conn).to receive(:stream_thread=).with(an_instance_of(Thread))
      described_class.create_sse_stream(client_conn, endpoint_url, logger)
    end

    it "joins the thread before returning" do
      # Create a real thread that we can control
      allow(Thread).to receive(:new).and_return(real_thread)
      expect(real_thread).to receive(:join)
      described_class.create_sse_stream(client_conn, endpoint_url, logger)
    end
  end
end