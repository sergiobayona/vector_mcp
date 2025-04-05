# frozen_string_literal: true

require "spec_helper"
require "stringio"

RSpec.describe MCPRuby::Transport::Stdio do
  let(:server) { instance_double("MCPRuby::Server") }
  let(:logger) { instance_double("Logger") }
  let(:session) { instance_double("MCPRuby::Session") }
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
    allow(MCPRuby::Session).to receive(:new).and_return(session)
  end

  describe "#initialize" do
    it "sets up the server and logger" do
      expect(transport.server).to eq(server)
      expect(transport.logger).to eq(logger)
    end

    it "initializes buffer and parser state" do
      expect(transport.instance_variable_get(:@buffer)).to eq("")
      expect(transport.instance_variable_get(:@json_depth)).to eq(0)
      expect(transport.instance_variable_get(:@in_string)).to eq(false)
      expect(transport.instance_variable_get(:@escape_next)).to eq(false)
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
        transport
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
      input.string = '{"id": "123", invalid json' + "\n"
      input.rewind

      transport.run

      puts "Debug - Output string: #{output.string.inspect}" # Debug line
      puts "Debug - Buffer after run: #{transport.instance_variable_get(:@buffer).inspect}" # Debug line
      puts "Debug - Logger calls:" # Debug line
      logger.messages.each { |msg| puts "  #{msg}" } if logger.respond_to?(:messages) # Debug line

      # Skip debug output lines
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
      expect(logger).to have_received(:error).with(/JSON Parse Error/)
    end

    it "processes multiple JSON messages from a single input" do
      message1 = { jsonrpc: "2.0", method: "test1", id: 1 }
      message2 = { jsonrpc: "2.0", method: "test2", id: 2 }
      input.string = "#{message1.to_json}#{message2.to_json}\n"
      input.rewind

      allow(server).to receive(:handle_message).and_return(nil)
      allow(session).to receive(:initialized?).and_return(true)

      transport.run

      expect(server).to have_received(:handle_message).with(
        hash_including("method" => "test1", "id" => 1),
        session,
        transport
      )
      expect(server).to have_received(:handle_message).with(
        hash_including("method" => "test2", "id" => 2),
        session,
        transport
      )
    end

    it "handles interrupts gracefully" do
      # Override read_chunk method to raise Interrupt
      allow(transport).to receive(:read_chunk).and_raise(Interrupt)

      transport.run

      expect(logger).to have_received(:info).with("Interrupt received, shutting down gracefully.")
    end
    it "handles fatal errors" do
      # Override read_chunk method to raise StandardError
      allow(transport).to receive(:read_chunk).and_raise(StandardError, "Fatal error")

      expect { transport.run }.to raise_error(StandardError, "Fatal error")
      expect(logger).to have_received(:fatal).with(/Fatal error in stdio transport loop: Fatal error/)
    end
  end

  describe "#process_buffer" do
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
      allow($stdout).to receive(:puts).and_raise(StandardError, "Write error")

      transport.send_response("123", { result: "success" })
      expect(logger).to have_received(:error).with("Failed to send message: Write error")
    end
  end

  describe "error handling" do
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
        MCPRuby::ProtocolError.new("Protocol error", code: -32_600, request_id: "123")
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
