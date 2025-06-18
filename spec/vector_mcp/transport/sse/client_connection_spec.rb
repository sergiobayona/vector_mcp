# frozen_string_literal: true

require "spec_helper"
require "vector_mcp/transport/sse/client_connection"

RSpec.describe VectorMCP::Transport::SSE::ClientConnection do
  let(:session_id) { "test-session-123" }
  let(:logger) { instance_double(Logger, debug: nil, warn: nil, error: nil, info: nil) }
  let(:client_connection) { described_class.new(session_id, logger) }

  describe "#initialize" do
    it "sets the correct attributes" do
      expect(client_connection.session_id).to eq(session_id)
      expect(client_connection.logger).to eq(logger)
      expect(client_connection.message_queue).to be_a(Queue)
      expect(client_connection.stream_thread).to be_nil
      expect(client_connection.stream_io).to be_nil
      expect(client_connection.closed?).to be false
    end

    it "logs the creation" do
      expect(logger).to receive(:debug)
      described_class.new(session_id, logger)
    end
  end

  describe "#closed?" do
    it "returns false when connection is open" do
      expect(client_connection.closed?).to be false
    end

    it "returns true when connection is closed" do
      client_connection.close
      expect(client_connection.closed?).to be true
    end
  end

  describe "#enqueue_message" do
    let(:message) { { jsonrpc: "2.0", method: "test", params: {} } }

    context "when connection is open" do
      it "enqueues the message successfully" do
        expect(client_connection.enqueue_message(message)).to be true
        expect(client_connection.queue_size).to eq(1)
      end

      it "logs the enqueuing" do
        expect(logger).to receive(:debug)
        client_connection.enqueue_message(message)
      end
    end

    context "when connection is closed" do
      before { client_connection.close }

      it "returns false" do
        expect(client_connection.enqueue_message(message)).to be false
      end

      it "does not enqueue the message" do
        client_connection.enqueue_message(message)
        expect(client_connection.queue_size).to eq(0)
      end
    end

    context "when queue raises an error" do
      before do
        allow(client_connection.message_queue).to receive(:push).and_raise(StandardError, "Queue error")
      end

      it "returns false" do
        expect(client_connection.enqueue_message(message)).to be false
      end

      it "logs the error" do
        expect(logger).to receive(:error)
        client_connection.enqueue_message(message)
      end
    end
  end

  describe "#dequeue_message" do
    let(:message) { { jsonrpc: "2.0", method: "test" } }

    context "when connection is open and queue has messages" do
      before { client_connection.enqueue_message(message) }

      it "returns the message" do
        expect(client_connection.dequeue_message).to eq(message)
      end

      it "removes the message from queue" do
        client_connection.dequeue_message
        expect(client_connection.queue_size).to eq(0)
      end
    end

    context "when connection is closed" do
      before { client_connection.close }

      it "returns nil" do
        expect(client_connection.dequeue_message).to be_nil
      end
    end

    context "when queue raises ClosedQueueError" do
      before do
        allow(client_connection.message_queue).to receive(:pop).and_raise(ClosedQueueError)
      end

      it "returns nil" do
        expect(client_connection.dequeue_message).to be_nil
      end
    end

    context "when queue raises other error" do
      before do
        allow(client_connection.message_queue).to receive(:pop).and_raise(StandardError, "Queue error")
      end

      it "returns nil" do
        expect(client_connection.dequeue_message).to be_nil
      end

      it "logs the error" do
        expect(logger).to receive(:error)
        client_connection.dequeue_message
      end
    end
  end

  describe "#queue_size" do
    it "returns 0 for empty queue" do
      expect(client_connection.queue_size).to eq(0)
    end

    it "returns correct size with messages" do
      client_connection.enqueue_message({ test: 1 })
      client_connection.enqueue_message({ test: 2 })
      expect(client_connection.queue_size).to eq(2)
    end

    it "handles errors gracefully" do
      allow(client_connection.message_queue).to receive(:size).and_raise(StandardError)
      expect(client_connection.queue_size).to eq(0)
    end
  end

  describe "#close" do
    let(:mock_thread) { instance_double(Thread, alive?: true, kill: nil, join: nil) }
    let(:mock_io) { instance_double(IO, close: nil) }

    before do
      client_connection.stream_thread = mock_thread
      client_connection.stream_io = mock_io
    end

    it "sets closed flag to true" do
      client_connection.close
      expect(client_connection.closed?).to be true
    end

    it "logs the closing" do
      expect(logger).to receive(:debug).twice # create + close
      client_connection.close
    end

    it "closes the message queue" do
      expect(client_connection.message_queue).to receive(:close)
      client_connection.close
    end

    it "closes the stream IO" do
      expect(mock_io).to receive(:close)
      client_connection.close
    end

    it "stops the streaming thread" do
      expect(mock_thread).to receive(:kill)
      expect(mock_thread).to receive(:join).with(1)
      client_connection.close
    end

    it "handles IO close errors gracefully" do
      allow(mock_io).to receive(:close).and_raise(StandardError, "IO error")
      expect(logger).to receive(:warn)
      expect { client_connection.close }.not_to raise_error
    end

    it "can be called multiple times safely" do
      client_connection.close
      expect { client_connection.close }.not_to raise_error
      expect(client_connection.closed?).to be true
    end

    context "when thread is not alive" do
      before { allow(mock_thread).to receive(:alive?).and_return(false) }

      it "does not try to kill the thread" do
        expect(mock_thread).not_to receive(:kill)
        expect(mock_thread).not_to receive(:join)
        client_connection.close
      end
    end

    context "when no thread is set" do
      before { client_connection.stream_thread = nil }

      it "does not raise an error" do
        expect { client_connection.close }.not_to raise_error
      end
    end

    context "when no IO is set" do
      before { client_connection.stream_io = nil }

      it "does not raise an error" do
        expect { client_connection.close }.not_to raise_error
      end
    end
  end

  describe "thread safety" do
    it "allows concurrent access to enqueue and dequeue" do
      messages = []
      threads = []

      # Producer thread
      threads << Thread.new do
        10.times do |i|
          client_connection.enqueue_message({ id: i })
          sleep(0.001)
        end
      end

      # Consumer thread
      threads << Thread.new do
        loop do
          message = client_connection.dequeue_message
          break if message.nil?

          messages << message
        end
      end

      # Let threads run
      sleep(0.1)
      client_connection.close
      threads.each(&:join)

      expect(messages.length).to be <= 10
      expect(messages.all? { |m| m.key?(:id) }).to be true
    end
  end
end