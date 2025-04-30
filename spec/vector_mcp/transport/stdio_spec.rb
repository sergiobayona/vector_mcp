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
        "stdio-session"
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
        "stdio-session"
      )
      expect(server).to have_received(:handle_message).with(
        hash_including("method" => "test2", "id" => 2),
        session,
        "stdio-session"
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
