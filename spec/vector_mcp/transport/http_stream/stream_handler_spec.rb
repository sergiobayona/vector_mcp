# frozen_string_literal: true

require "spec_helper"
require "vector_mcp/transport/http_stream"

RSpec.describe VectorMCP::Transport::HttpStream::StreamHandler do
  let(:mock_logger) { instance_double(Logger, info: nil, debug: nil, warn: nil, error: nil) }
  let(:mock_server) { instance_double(VectorMCP::Server, logger: mock_logger) }
  let(:mock_event_store) { instance_double(VectorMCP::Transport::HttpStream::EventStore) }
  let(:mock_session_manager) { instance_double(VectorMCP::Transport::HttpStream::SessionManager) }
  let(:mock_transport) do
    instance_double(
      VectorMCP::Transport::HttpStream,
      logger: mock_logger,
      server: mock_server,
      event_store: mock_event_store,
      session_manager: mock_session_manager
    )
  end
  let(:stream_handler) { described_class.new(mock_transport) }

  # Mock session and connection objects
  let(:session_id) { "test-session-123" }
  let(:mock_session_context) { instance_double(VectorMCP::Session, id: session_id) }
  let(:mock_session) do
    VectorMCP::Transport::HttpStream::SessionManager::Session.new(
      session_id,
      mock_session_context,
      Time.now,
      Time.now,
      { streaming_connection: nil }
    )
  end

  describe "#initialize" do
    it "initializes with transport and logger" do
      expect(stream_handler.transport).to eq(mock_transport)
      expect(stream_handler.logger).to eq(mock_logger)
    end

    it "initializes with empty active connections" do
      connections = stream_handler.instance_variable_get(:@active_connections)
      expect(connections).to be_a(Concurrent::Hash)
      expect(connections).to be_empty
    end
  end

  describe "#handle_streaming_request" do
    let(:rack_env) do
      {
        "HTTP_LAST_EVENT_ID" => "event-123",
        "REQUEST_METHOD" => "GET",
        "PATH_INFO" => "/mcp"
      }
    end

    before do
      allow(mock_session).to receive(:streaming?).and_return(false)
      allow(mock_session).to receive(:streaming_connection=)
      allow(mock_session_manager).to receive(:set_streaming_connection)
      allow(mock_event_store).to receive(:store_event).and_return("event-456")
    end

    it "extracts Last-Event-ID from headers" do
      response = stream_handler.handle_streaming_request(rack_env, mock_session)
      
      expect(response).to be_an(Array)
      expect(response[0]).to eq(200) # HTTP status
      expect(response[1]).to include("Content-Type" => "text/event-stream")
      expect(response[2]).to be_an(Enumerator) # SSE stream
    end

    it "handles missing Last-Event-ID header" do
      env_without_last_event_id = rack_env.except("HTTP_LAST_EVENT_ID")
      
      response = stream_handler.handle_streaming_request(env_without_last_event_id, mock_session)
      
      expect(response[0]).to eq(200)
      expect(response[1]).to include("Content-Type" => "text/event-stream")
    end

    it "builds proper SSE headers" do
      response = stream_handler.handle_streaming_request(rack_env, mock_session)
      
      headers = response[1]
      expect(headers["Content-Type"]).to eq("text/event-stream")
      expect(headers["Cache-Control"]).to eq("no-cache")
      expect(headers["Connection"]).to eq("keep-alive")
      expect(headers["X-Accel-Buffering"]).to eq("no")
      expect(headers["Access-Control-Allow-Origin"]).to eq("*")
      expect(headers["Access-Control-Allow-Headers"]).to eq("Last-Event-ID")
    end

    it "creates SSE stream enumerator" do
      response = stream_handler.handle_streaming_request(rack_env, mock_session)
      
      stream = response[2]
      expect(stream).to be_an(Enumerator)
    end

    it "logs streaming start" do
      expect(mock_logger).to receive(:info).with(/Starting SSE stream for session #{session_id}/)
      
      stream_handler.handle_streaming_request(rack_env, mock_session)
    end
  end

  describe "#send_message_to_session" do
    let(:message) { { "jsonrpc" => "2.0", "method" => "test", "params" => { "data" => "test" } } }
    let(:mock_connection) { instance_double(VectorMCP::Transport::HttpStream::StreamHandler::StreamingConnection) }
    let(:mock_yielder) { instance_double(Enumerator::Yielder) }

    before do
      allow(mock_session).to receive(:streaming?).and_return(true)
      allow(mock_connection).to receive(:closed?).and_return(false)
      allow(mock_connection).to receive(:yielder).and_return(mock_yielder)
      allow(mock_connection).to receive(:close)
      allow(mock_session_manager).to receive(:remove_streaming_connection)
      allow(mock_event_store).to receive(:store_event).and_return("event-789")
      allow(mock_yielder).to receive(:<<)
    end

    context "when session has streaming connection" do
      before do
        stream_handler.instance_variable_get(:@active_connections)[session_id] = mock_connection
      end

      it "sends message successfully" do
        result = stream_handler.send_message_to_session(mock_session, message)
        
        expect(result).to be true
        expect(mock_event_store).to have_received(:store_event).with(message.to_json, "message")
        expect(mock_yielder).to have_received(:<<).with(/^id: event-789/)
      end

      it "formats message as SSE event" do
        stream_handler.send_message_to_session(mock_session, message)
        
        expect(mock_yielder).to have_received(:<<) do |sse_event|
          expect(sse_event).to include("id: event-789")
          expect(sse_event).to include("event: message")
          expect(sse_event).to include("data: #{message.to_json}")
          expect(sse_event).to end_with("\n\n")
        end
      end

      it "logs successful message send" do
        expect(mock_logger).to receive(:debug).with(/Message sent to session #{session_id}/)
        
        stream_handler.send_message_to_session(mock_session, message)
      end

      it "handles yielder errors gracefully" do
        allow(mock_yielder).to receive(:<<).and_raise(StandardError.new("Connection closed"))
        expect(mock_logger).to receive(:error).with(/Error sending message to session #{session_id}/)
        
        result = stream_handler.send_message_to_session(mock_session, message)
        
        expect(result).to be false
      end

      it "cleans up connection on error" do
        allow(mock_yielder).to receive(:<<).and_raise(StandardError.new("Connection closed"))
        expect(mock_session_manager).to receive(:remove_streaming_connection).with(mock_session)
        
        stream_handler.send_message_to_session(mock_session, message)
      end
    end

    context "when session doesn't have streaming connection" do
      it "returns false for non-streaming session" do
        allow(mock_session).to receive(:streaming?).and_return(false)
        
        result = stream_handler.send_message_to_session(mock_session, message)
        
        expect(result).to be false
      end

      it "returns false for missing connection" do
        # No connection in @active_connections
        
        result = stream_handler.send_message_to_session(mock_session, message)
        
        expect(result).to be false
      end

      it "returns false for closed connection" do
        allow(mock_connection).to receive(:closed?).and_return(true)
        stream_handler.instance_variable_get(:@active_connections)[session_id] = mock_connection
        
        result = stream_handler.send_message_to_session(mock_session, message)
        
        expect(result).to be false
      end
    end
  end

  describe "#active_connection_count" do
    let(:mock_connection1) { instance_double(VectorMCP::Transport::HttpStream::StreamHandler::StreamingConnection) }
    let(:mock_connection2) { instance_double(VectorMCP::Transport::HttpStream::StreamHandler::StreamingConnection) }

    it "returns 0 when no connections" do
      expect(stream_handler.active_connection_count).to eq(0)
    end

    it "returns count of active connections" do
      active_connections = stream_handler.instance_variable_get(:@active_connections)
      active_connections["session-1"] = mock_connection1
      active_connections["session-2"] = mock_connection2
      
      expect(stream_handler.active_connection_count).to eq(2)
    end
  end

  describe "#cleanup_all_connections" do
    let(:mock_connection1) { instance_double(VectorMCP::Transport::HttpStream::StreamHandler::StreamingConnection) }
    let(:mock_connection2) { instance_double(VectorMCP::Transport::HttpStream::StreamHandler::StreamingConnection) }

    before do
      allow(mock_connection1).to receive(:close)
      allow(mock_connection2).to receive(:close)
    end

    it "logs cleanup activity" do
      active_connections = stream_handler.instance_variable_get(:@active_connections)
      active_connections["session-1"] = mock_connection1
      active_connections["session-2"] = mock_connection2
      
      expect(mock_logger).to receive(:info).with(/Cleaning up all streaming connections: 2/)
      
      stream_handler.cleanup_all_connections
    end

    it "closes all connections" do
      active_connections = stream_handler.instance_variable_get(:@active_connections)
      active_connections["session-1"] = mock_connection1
      active_connections["session-2"] = mock_connection2
      
      stream_handler.cleanup_all_connections
      
      expect(mock_connection1).to have_received(:close)
      expect(mock_connection2).to have_received(:close)
    end

    it "clears active connections hash" do
      active_connections = stream_handler.instance_variable_get(:@active_connections)
      active_connections["session-1"] = mock_connection1
      active_connections["session-2"] = mock_connection2
      
      stream_handler.cleanup_all_connections
      
      expect(active_connections).to be_empty
    end
  end

  describe "private methods" do
    describe "#extract_last_event_id" do
      it "extracts Last-Event-ID from headers" do
        env = { "HTTP_LAST_EVENT_ID" => "event-123" }
        
        result = stream_handler.send(:extract_last_event_id, env)
        
        expect(result).to eq("event-123")
      end

      it "returns nil when header is missing" do
        env = {}
        
        result = stream_handler.send(:extract_last_event_id, env)
        
        expect(result).to be_nil
      end
    end

    describe "#build_sse_headers" do
      it "builds proper SSE headers" do
        headers = stream_handler.send(:build_sse_headers)
        
        expect(headers).to eq({
          "Content-Type" => "text/event-stream",
          "Cache-Control" => "no-cache",
          "Connection" => "keep-alive",
          "X-Accel-Buffering" => "no",
          "Access-Control-Allow-Origin" => "*",
          "Access-Control-Allow-Headers" => "Last-Event-ID"
        })
      end
    end

    describe "#format_sse_event" do
      it "formats event with all fields" do
        result = stream_handler.send(:format_sse_event, "test data", "message", "event-123")
        
        expect(result).to eq("id: event-123\nevent: message\ndata: test data\n\n")
      end

      it "formats event without type" do
        result = stream_handler.send(:format_sse_event, "test data", nil, "event-123")
        
        expect(result).to eq("id: event-123\ndata: test data\n\n")
      end

      it "handles multiline data" do
        multiline_data = "line1\nline2\nline3"
        result = stream_handler.send(:format_sse_event, multiline_data, "message", "event-123")
        
        expect(result).to eq("id: event-123\nevent: message\ndata: #{multiline_data}\n\n")
      end
    end

    describe "#cleanup_connection" do
      let(:mock_connection) { instance_double(VectorMCP::Transport::HttpStream::StreamHandler::StreamingConnection) }

      before do
        allow(mock_connection).to receive(:close)
        allow(mock_session_manager).to receive(:remove_streaming_connection)
      end

      it "removes connection from active connections" do
        active_connections = stream_handler.instance_variable_get(:@active_connections)
        active_connections[session_id] = mock_connection
        
        stream_handler.send(:cleanup_connection, mock_session)
        
        expect(active_connections[session_id]).to be_nil
      end

      it "closes the connection" do
        active_connections = stream_handler.instance_variable_get(:@active_connections)
        active_connections[session_id] = mock_connection
        
        stream_handler.send(:cleanup_connection, mock_session)
        
        expect(mock_connection).to have_received(:close)
      end

      it "removes streaming connection from session manager" do
        active_connections = stream_handler.instance_variable_get(:@active_connections)
        active_connections[session_id] = mock_connection
        
        stream_handler.send(:cleanup_connection, mock_session)
        
        expect(mock_session_manager).to have_received(:remove_streaming_connection).with(mock_session)
      end

      it "logs cleanup activity" do
        active_connections = stream_handler.instance_variable_get(:@active_connections)
        active_connections[session_id] = mock_connection
        
        expect(mock_logger).to receive(:debug).with(/Streaming connection cleaned up for #{session_id}/)
        
        stream_handler.send(:cleanup_connection, mock_session)
      end

      it "handles missing connection gracefully" do
        expect { stream_handler.send(:cleanup_connection, mock_session) }.not_to raise_error
      end
    end
  end

  describe "streaming workflow integration" do
    let(:mock_yielder) { instance_double(Enumerator::Yielder) }
    let(:mock_thread) { instance_double(Thread) }

    before do
      allow(mock_session).to receive(:streaming?).and_return(false)
      allow(mock_session).to receive(:streaming_connection=)
      allow(mock_session_manager).to receive(:set_streaming_connection)
      allow(mock_session_manager).to receive(:remove_streaming_connection)
      allow(mock_event_store).to receive(:store_event).and_return("event-123")
      allow(mock_event_store).to receive(:get_events_after).and_return([])
      allow(mock_yielder).to receive(:<<)
      allow(Thread).to receive(:new).and_yield.and_return(mock_thread)
      allow(mock_thread).to receive(:join)
    end

    describe "SSE stream creation" do
      it "creates streaming connection and registers it" do
        expect(mock_session_manager).to receive(:set_streaming_connection).with(mock_session, anything)
        
        enumerator = stream_handler.send(:create_sse_stream, mock_session, nil)
        # Execute the enumerator block to trigger the setup
        enumerator.peek rescue nil
      end

      it "sends initial connection established event" do
        expect(mock_event_store).to receive(:store_event).with(anything, "connection")
        
        enumerator = stream_handler.send(:create_sse_stream, mock_session, nil)
        # Execute the enumerator block to trigger the setup
        begin
          enumerator.first
        rescue StopIteration
          # Expected when enumerator is exhausted
        end
      end

      it "starts streaming thread" do
        expect(Thread).to receive(:new).and_yield
        
        enumerator = stream_handler.send(:create_sse_stream, mock_session, nil)
        # Execute the enumerator block to trigger the setup
        begin
          enumerator.first
        rescue StopIteration
          # Expected when enumerator is exhausted
        end
      end
    end

    describe "event replay functionality" do
      let(:mock_event1) { instance_double(VectorMCP::Transport::HttpStream::EventStore::Event) }
      let(:mock_event2) { instance_double(VectorMCP::Transport::HttpStream::EventStore::Event) }
      let(:last_event_id) { "event-456" }

      before do
        allow(mock_event1).to receive(:to_sse_format).and_return("id: event-457\ndata: test1\n\n")
        allow(mock_event2).to receive(:to_sse_format).and_return("id: event-458\ndata: test2\n\n")
        allow(mock_event_store).to receive(:get_events_after).with(last_event_id).and_return([mock_event1, mock_event2])
      end

      it "replays missed events after Last-Event-ID" do
        expect(mock_logger).to receive(:info).with(/Replaying 2 missed events from #{last_event_id}/)
        
        stream_handler.send(:replay_events, mock_yielder, last_event_id)
        
        expect(mock_yielder).to have_received(:<<).with("id: event-457\ndata: test1\n\n")
        expect(mock_yielder).to have_received(:<<).with("id: event-458\ndata: test2\n\n")
      end

      it "handles empty missed events" do
        allow(mock_event_store).to receive(:get_events_after).and_return([])
        
        expect(mock_logger).to receive(:info).with(/Replaying 0 missed events/)
        
        stream_handler.send(:replay_events, mock_yielder, last_event_id)
      end
    end

    describe "heartbeat functionality" do
      let(:mock_connection) { instance_double(VectorMCP::Transport::HttpStream::StreamHandler::StreamingConnection) }

      before do
        allow(mock_connection).to receive(:closed?).and_return(false, false, true) # Stop after 2 iterations
        stream_handler.instance_variable_get(:@active_connections)[session_id] = mock_connection
        allow(stream_handler).to receive(:sleep) # Mock sleep to speed up tests
      end

      it "sends periodic heartbeat events" do
        expect(mock_event_store).to receive(:store_event).with(anything, "heartbeat").at_least(:once)
        
        stream_handler.send(:keep_alive_loop, mock_session, mock_yielder)
      end

      it "stops when connection is closed" do
        allow(mock_connection).to receive(:closed?).and_return(true)
        
        # Should not send heartbeat if connection is closed
        expect(mock_event_store).not_to receive(:store_event).with(anything, "heartbeat")
        
        stream_handler.send(:keep_alive_loop, mock_session, mock_yielder)
      end

      it "handles heartbeat send failures gracefully" do
        allow(mock_yielder).to receive(:<<).and_raise(StandardError.new("Connection closed"))
        
        expect(mock_logger).to receive(:debug).with(/Heartbeat failed for #{session_id}/)
        
        stream_handler.send(:keep_alive_loop, mock_session, mock_yielder)
      end

      it "stops when connection is removed from active connections" do
        stream_handler.instance_variable_get(:@active_connections).delete(session_id)
        
        expect(mock_event_store).not_to receive(:store_event).with(anything, "heartbeat")
        
        stream_handler.send(:keep_alive_loop, mock_session, mock_yielder)
      end
    end
  end

  describe "StreamingConnection struct" do
    let(:mock_thread) { instance_double(Thread) }
    let(:mock_yielder) { instance_double(Enumerator::Yielder) }

    describe "initialization" do
      it "creates with all required fields" do
        connection = VectorMCP::Transport::HttpStream::StreamHandler::StreamingConnection.new(
          mock_session, mock_yielder, mock_thread, false
        )
        
        expect(connection.session).to eq(mock_session)
        expect(connection.yielder).to eq(mock_yielder)
        expect(connection.thread).to eq(mock_thread)
        expect(connection.closed).to be false
      end
    end

    describe "#close" do
      it "marks connection as closed" do
        allow(mock_thread).to receive(:kill)
        connection = VectorMCP::Transport::HttpStream::StreamHandler::StreamingConnection.new(
          mock_session, mock_yielder, mock_thread, false
        )
        
        connection.close
        
        expect(connection.closed).to be true
      end

      it "kills the thread" do
        allow(mock_thread).to receive(:kill)
        connection = VectorMCP::Transport::HttpStream::StreamHandler::StreamingConnection.new(
          mock_session, mock_yielder, mock_thread, false
        )
        
        connection.close
        
        expect(mock_thread).to have_received(:kill)
      end

      it "handles nil thread gracefully" do
        connection = VectorMCP::Transport::HttpStream::StreamHandler::StreamingConnection.new(
          mock_session, mock_yielder, nil, false
        )
        
        expect { connection.close }.not_to raise_error
      end
    end

    describe "#closed?" do
      it "returns true when closed" do
        connection = VectorMCP::Transport::HttpStream::StreamHandler::StreamingConnection.new(
          mock_session, mock_yielder, mock_thread, true
        )
        
        expect(connection.closed?).to be true
      end

      it "returns false when not closed" do
        connection = VectorMCP::Transport::HttpStream::StreamHandler::StreamingConnection.new(
          mock_session, mock_yielder, mock_thread, false
        )
        
        expect(connection.closed?).to be false
      end
    end
  end

  describe "error handling scenarios" do
    let(:mock_yielder) { instance_double(Enumerator::Yielder) }
    let(:mock_connection) { instance_double(VectorMCP::Transport::HttpStream::StreamHandler::StreamingConnection) }

    describe "streaming thread errors" do
      before do
        allow(mock_session).to receive(:streaming?).and_return(false)
        allow(mock_session).to receive(:streaming_connection=)
        allow(mock_session_manager).to receive(:set_streaming_connection)
        allow(mock_session_manager).to receive(:remove_streaming_connection)
        allow(mock_event_store).to receive(:store_event).and_return("event-123")
        allow(mock_yielder).to receive(:<<)
      end

      it "logs streaming thread errors" do
        error_message = "Streaming thread error"
        allow(stream_handler).to receive(:stream_to_client).and_raise(StandardError.new(error_message))
        
        expect(mock_logger).to receive(:error).with(/Error in streaming thread for #{session_id}: #{error_message}/)
        
        enumerator = stream_handler.send(:create_sse_stream, mock_session, nil)
        # The error is caught and logged inside the thread, so the enumerator should not raise
        begin
          enumerator.first
        rescue StopIteration
          # Expected when enumerator is exhausted
        end
      end

      it "ensures connection cleanup on thread error" do
        # Test that cleanup_connection is called when an error occurs in the thread
        allow(stream_handler).to receive(:stream_to_client).and_raise(StandardError.new("Thread error"))
        expect(stream_handler).to receive(:cleanup_connection).with(mock_session)
        
        enumerator = stream_handler.send(:create_sse_stream, mock_session, nil)
        # The error is caught and cleanup happens inside the thread
        begin
          enumerator.first
        rescue StopIteration
          # Expected when enumerator is exhausted
        end
      end
    end

    describe "event store errors" do
      let(:message) { { "jsonrpc" => "2.0", "method" => "test" } }

      before do
        allow(mock_session).to receive(:streaming?).and_return(true)
        allow(mock_connection).to receive(:closed?).and_return(false)
        allow(mock_connection).to receive(:yielder).and_return(mock_yielder)
        allow(mock_connection).to receive(:close)
        allow(mock_session_manager).to receive(:remove_streaming_connection)
        allow(mock_yielder).to receive(:<<)
        stream_handler.instance_variable_get(:@active_connections)[session_id] = mock_connection
      end

      it "handles event store errors gracefully" do
        allow(mock_event_store).to receive(:store_event).and_raise(StandardError.new("Storage error"))
        
        expect(mock_logger).to receive(:error).with(/Error sending message to session #{session_id}/)
        
        result = stream_handler.send_message_to_session(mock_session, message)
        
        expect(result).to be false
      end
    end
  end

  describe "thread safety" do
    let(:mock_yielder) { instance_double(Enumerator::Yielder) }
    let(:message) { { "jsonrpc" => "2.0", "method" => "test" } }

    before do
      allow(mock_session).to receive(:streaming?).and_return(true)
      allow(mock_event_store).to receive(:store_event).and_return("event-123")
      allow(mock_yielder).to receive(:<<)
    end

    it "handles concurrent connection operations" do
      connections = []
      threads = []

      5.times do |i|
        threads << Thread.new do
          connection = VectorMCP::Transport::HttpStream::StreamHandler::StreamingConnection.new(
            mock_session, mock_yielder, nil, false
          )
          stream_handler.instance_variable_get(:@active_connections)["session-#{i}"] = connection
          connections << connection
        end
      end

      threads.each(&:join)
      
      expect(stream_handler.active_connection_count).to eq(5)
      expect(connections.length).to eq(5)
    end

    it "handles concurrent message sending" do
      connection = VectorMCP::Transport::HttpStream::StreamHandler::StreamingConnection.new(
        mock_session, mock_yielder, nil, false
      )
      allow(connection).to receive(:closed?).and_return(false)
      allow(connection).to receive(:yielder).and_return(mock_yielder)
      
      stream_handler.instance_variable_get(:@active_connections)[session_id] = connection
      
      threads = []
      results = []

      10.times do
        threads << Thread.new do
          result = stream_handler.send_message_to_session(mock_session, message)
          results << result
        end
      end

      threads.each(&:join)
      
      expect(results.all?).to be true
      expect(results.length).to eq(10)
    end
  end
end