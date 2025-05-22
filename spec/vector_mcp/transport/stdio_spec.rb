# frozen_string_literal: true

require "spec_helper"
require "stringio"

RSpec.describe VectorMCP::Transport::Stdio do
  let(:server) { instance_double("VectorMCP::Server") }
  let(:logger) { instance_double("Logger") }
  let(:session) { instance_double("VectorMCP::Session") }
  let(:server_info) { { name: "test", version: "1.0.0" } }
  let(:server_capabilities) { { tools: { listChanged: false } } }
  let(:protocol_version) { "2024-11-05" }

  subject(:transport) { described_class.new(server) }

  before do
    allow(server).to receive(:logger).and_return(logger)
    allow(logger).to receive(:info)
    allow(logger).to receive(:error)
    allow(logger).to receive(:debug)
    allow(logger).to receive(:warn)
    allow(logger).to receive(:fatal)
    allow(server).to receive(:server_info).and_return(server_info)
    allow(server).to receive(:server_capabilities).and_return(server_capabilities)
    allow(server).to receive(:protocol_version).and_return(protocol_version)
    allow(VectorMCP::Session).to receive(:new).and_return(session)
    allow(session).to receive(:id).and_return("mock_session_id")
  end

  describe "#initialize" do
    it "sets up the server and logger" do
      expect(transport.server).to eq(server)
      expect(transport.logger).to eq(logger)
    end

    it "initializes with proper state" do
      expect(transport.instance_variable_get(:@running)).to eq(false)
      expect(transport.instance_variable_get(:@input_mutex)).to be_a(Mutex)
      expect(transport.instance_variable_get(:@output_mutex)).to be_a(Mutex)
    end
  end

  describe "#run" do
    let(:original_stdin) { $stdin }
    let(:original_stdout) { $stdout }
    let(:input) { StringIO.new }
    let(:output) { StringIO.new }

    before do
      $stdin = input
      $stdout = output
    end

    after do
      $stdin = original_stdin
      $stdout = original_stdout
    end

    it "processes valid JSON-RPC messages" do
      message = { jsonrpc: "2.0", method: "test", id: 1 }
      input.string = "#{message.to_json}\n"
      input.rewind

      allow(server).to receive(:handle_message).and_return(nil)
      allow(session).to receive(:initialized?).and_return(true)

      transport.run

      expect(server).to have_received(:handle_message).with(
        hash_including("method" => "test", "id" => 1),
        session,
        "mock_session_id"
      )
    end

    it "skips empty lines" do
      input.string = "\n   \n  \t  \n"
      input.rewind

      allow(server).to receive(:handle_message)

      transport.run

      expect(server).not_to have_received(:handle_message)
    end

    it "handles JSON parse errors" do
      input.string = "{\"id\": \"123\", invalid json\n"
      input.rewind

      transport.run

      # Find the JSON response in the output
      output_lines = output.string.lines
      json_line = output_lines.find { |line| line.start_with?("{") }
      expect(json_line).not_to be_nil, "No JSON response found in output"

      output_message = JSON.parse(json_line)
      expect(output_message).to include(
        "jsonrpc" => "2.0",
        "id" => "123",
        "error" => hash_including(
          "code" => -32_700,
          "message" => "Parse error"
        )
      )
      expect(logger).to have_received(:error).with(/Failed to parse message as JSON/)
    end

    it "processes multiple JSON messages from separate lines" do
      message1 = { jsonrpc: "2.0", method: "test1", id: 1 }
      message2 = { jsonrpc: "2.0", method: "test2", id: 2 }
      # Put each message on a separate line
      input.string = "#{message1.to_json}\n#{message2.to_json}\n"
      input.rewind

      allow(server).to receive(:handle_message).and_return(nil)
      allow(session).to receive(:initialized?).and_return(true)

      transport.run

      expect(server).to have_received(:handle_message).with(
        hash_including("method" => "test1", "id" => 1),
        session,
        "mock_session_id"
      )
      expect(server).to have_received(:handle_message).with(
        hash_including("method" => "test2", "id" => 2),
        session,
        "mock_session_id"
      )
    end

    it "handles interrupts gracefully" do
      # Force stdin to raise Interrupt when read
      allow($stdin).to receive(:gets).and_raise(Interrupt)

      # Run the transport
      transport.run

      # Verify the log messages show graceful shutdown
      expect(logger).to have_received(:info).with("Starting stdio transport")
      expect(logger).to have_received(:info).with("Interrupted. Shutting down...")
      expect(logger).to have_received(:info).with("Stdio transport shut down")
    end

    it "handles fatal errors" do
      # Force read_input_line to raise a fatal error
      allow_any_instance_of(StringIO).to receive(:gets).and_raise(StandardError, "Fatal error")

      # Run the transport with expectation of exiting
      expect { transport.run }.to raise_error(SystemExit)

      # Verify error was logged
      expect(logger).to have_received(:error).with(/Fatal error in input thread: Fatal error/)
    end
  end

  describe "#run cleanup" do
    it "kills the input_thread in ensure block when still alive" do
      fake_thread = instance_double(Thread, join: nil, alive?: true, kill: nil)
      allow(Thread).to receive(:new).and_return(fake_thread)
      allow($stdin).to receive(:gets).and_raise(Interrupt) # immediately trigger interrupt

      transport.run

      expect(fake_thread).to have_received(:kill)
      expect(transport.instance_variable_get(:@running)).to eq(false)
    end
  end

  describe "#send_response" do
    let(:original_stdout) { $stdout }
    let(:output) { StringIO.new }

    before do
      $stdout = output
      allow(logger).to receive(:debug)
    end

    after do
      $stdout = original_stdout
    end

    it "sends a properly formatted JSON-RPC response" do
      transport.send_response("123", { result: "success" })

      output_message = JSON.parse(output.string)
      expect(output_message).to eq({
                                     "jsonrpc" => "2.0",
                                     "id" => "123",
                                     "result" => { "result" => "success" }
                                   })
    end

    it "handles errors during message sending" do
      # Simulate a write error that will be caught inside the implementation
      allow($stdout).to receive(:puts).and_raise(Errno::EPIPE, "Broken pipe")

      # No need to verify specific behavior other than it doesn't crash
      expect do
        transport.send_response("123", { result: "success" })
      end.not_to raise_error

      # We do expect the error to be logged
      expect(logger).to have_received(:error).with(/Output pipe closed/)
    end
  end

  describe "#send_notification" do
    let(:original_stdout) { $stdout }
    let(:output) { StringIO.new }

    before { $stdout = output }
    after { $stdout = original_stdout }

    it "writes a correct JSON-RPC notification" do
      transport.send_notification("someMethod", { foo: "bar" })
      json = JSON.parse(output.string)
      expect(json).to eq({
                           "jsonrpc" => "2.0",
                           "method" => "someMethod",
                           "params" => { "foo" => "bar" }
                         })
    end
  end

  describe "#shutdown" do
    it "sets @running to false and kills the input thread" do
      fake_thread = instance_double(Thread, alive?: true, kill: nil)
      transport.instance_variable_set(:@running, true)
      transport.instance_variable_set(:@input_thread, fake_thread)

      transport.shutdown

      expect(transport.instance_variable_get(:@running)).to eq(false)
      expect(fake_thread).to have_received(:kill)
    end
  end

  describe "#handle_input_line edge cases" do
    let(:session_id) { "stdio-session" }

    it "sends parse error with nil id when extract_id_from_invalid_json fails" do
      allow(VectorMCP::Util).to receive(:extract_id_from_invalid_json).and_raise(StandardError)
      allow(transport).to receive(:send_error)

      transport.send(:handle_input_line, "{ invalid json", session, session_id)

      expect(transport).to have_received(:send_error).with(nil, -32_700, "Parse error")
    end

    it "sends internal error with nil id when StandardError occurs and message has no id" do
      allow(server).to receive(:handle_message).and_raise(StandardError, "boom")
      allow(transport).to receive(:send_error)

      msg = { jsonrpc: "2.0", method: "foo" }.to_json
      transport.send(:handle_input_line, msg, session, session_id)

      expect(transport).to have_received(:send_error).with(nil, -32_603, "Internal error", anything)
    end

    it "does not send a response when message id is nil" do
      allow(server).to receive(:handle_message).and_return({ result: "ok" })
      allow(transport).to receive(:send_response)

      msg = { jsonrpc: "2.0", method: "foo" }.to_json
      transport.send(:handle_input_line, msg, session, session_id)

      expect(transport).not_to have_received(:send_response)
    end
  end

  describe "#write_message" do
    it "flushes $stdout after writing" do
      original_stdout = $stdout
      fake_stdout = StringIO.new
      # Spy on flush to confirm it is called while still preserving original behavior
      allow(fake_stdout).to receive(:flush).and_call_original
      # Allow puts to behave normally while still being spy-able
      allow(fake_stdout).to receive(:puts).and_call_original

      $stdout = fake_stdout

      transport.send(:write_message, { hello: "world" })

      expect(fake_stdout).to have_received(:flush)
    ensure
      $stdout = original_stdout
    end
  end

  describe "#send_request" do
    let(:method_name) { "test/echo" }
    let(:params) { { "message" => "hello" } }

    context "with invalid arguments" do
      it "raises ArgumentError if method is blank" do
        expect { transport.send_request("", params) }.to raise_error(ArgumentError, "Method cannot be blank")
        expect { transport.send_request("   ", params) }.to raise_error(ArgumentError, "Method cannot be blank")
        expect { transport.send_request(nil, params) }.to raise_error(ArgumentError, "Method cannot be blank")
      end
    end

    context "when timeout occurs" do
      it "raises a SamplingTimeoutError" do
        # Mock the condition variable and timeout behavior
        original_stdout = $stdout
        mock_stdout = StringIO.new
        $stdout = mock_stdout

        begin
          expect do
            transport.send_request(method_name, params, timeout: 0.001) # Very short timeout
          end.to raise_error(VectorMCP::SamplingTimeoutError, /Timeout waiting for client response to '#{method_name}' request/)

          # Verify that a request was written to stdout
          output = JSON.parse(mock_stdout.string)
          expect(output["method"]).to eq(method_name)
          expect(output["params"]).to eq(params)
          expect(logger).to have_received(:warn).with(/Timeout waiting for response to request ID/)
        ensure
          $stdout = original_stdout
        end
      end
    end
  end

  # NOTE: The following sections test private methods that no longer exist in the implementation
  # They are skipped to avoid test failures
  xdescribe "#process_buffer" do
    before do
      allow(transport).to receive(:handle_json_message)
    end

    it "correctly identifies complete JSON objects" do
      transport.instance_variable_set(:@buffer, '{"id": 1}')
      transport.send(:process_buffer, session)
      expect(transport).to have_received(:handle_json_message).with('{"id": 1}', session)
    end

    it "handles nested JSON structures" do
      nested_json = '{"id": 1, "data": {"nested": [1,2,3]}}'
      transport.instance_variable_set(:@buffer, nested_json)
      transport.send(:process_buffer, session)
      expect(transport).to have_received(:handle_json_message).with(nested_json, session)
    end

    it "correctly handles string escaping" do
      json_with_escapes = '{"id": 1, "data": "This has \\"quotes\\" and {braces}"}'
      transport.instance_variable_set(:@buffer, json_with_escapes)
      transport.send(:process_buffer, session)
      expect(transport).to have_received(:handle_json_message).with(json_with_escapes, session)
    end

    it "preserves incomplete JSON at end of buffer" do
      partial_json = '{"id": 1}{"incomplete": '
      transport.instance_variable_set(:@buffer, partial_json)
      transport.send(:process_buffer, session)
      expect(transport).to have_received(:handle_json_message).with('{"id": 1}', session)
      expect(transport.instance_variable_get(:@buffer)).to eq('{"incomplete": ')
    end
  end

  xdescribe "error handling" do
    let(:original_stdout) { $stdout }
    let(:output) { StringIO.new }

    before do
      $stdout = output
      allow(logger).to receive(:debug)
    end

    after do
      $stdout = original_stdout
    end

    it "handles protocol errors" do
      allow(server).to receive(:handle_message).and_raise(
        VectorMCP::ProtocolError.new("Protocol error", code: -32_600, request_id: "123")
      )

      transport.send(:handle_json_message, '{"id": "123", "method": "test"}', session)

      output_message = JSON.parse(output.string)
      expect(output_message).to include(
        "jsonrpc" => "2.0",
        "id" => "123",
        "error" => hash_including(
          "code" => -32_600,
          "message" => "Protocol error"
        )
      )
    end

    it "handles standard errors" do
      allow(server).to receive(:handle_message).and_raise(StandardError, "Unexpected error")

      transport.send(:handle_json_message, '{"id": "123", "method": "test"}', session)

      output_message = JSON.parse(output.string)
      expect(output_message).to include(
        "jsonrpc" => "2.0",
        "id" => "123",
        "error" => hash_including(
          "code" => -32_603,
          "message" => "Internal server error"
        )
      )
    end
  end
end
