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
      allow($stdin).to receive(:gets).and_return("#{message.to_json}\n", nil)
      allow(server).to receive(:handle_message)
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

      begin
        transport.run
      rescue EOFError
        # Expected
      end

      expect(server).not_to have_received(:handle_message)
    end

    it "handles JSON parse errors" do
      input.string = "invalid json\n"
      input.rewind

      begin
        transport.run
      rescue EOFError
        # Expected
      end

      output_messages = output.string.split("\n")
      expect(output_messages).to be_empty # No ID in invalid JSON, so no error response
      expect(logger).to have_received(:error).with(/JSON Parse Error/)
    end

    it "handles interrupts gracefully" do
      allow(input).to receive(:gets).and_raise(Interrupt)

      transport.run

      expect(logger).to have_received(:info).with("Interrupt received, shutting down gracefully.")
    end

    it "handles fatal errors" do
      allow(input).to receive(:gets).and_raise(StandardError, "Fatal error")

      expect { transport.run }.to raise_error(SystemExit)
      expect(logger).to have_received(:fatal).with(/Fatal error in stdio transport loop: Fatal error/)
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

    it "handles parse errors" do
      input = StringIO.new('{"id": "123", invalid json')
      allow($stdin).to receive(:gets).and_return(input.string, nil)

      begin
        transport.run
      rescue EOFError
        # Expected
      end

      output_message = JSON.parse(output.string)
      expect(output_message).to include(
        "jsonrpc" => "2.0",
        "id" => "123",
        "error" => hash_including(
          "code" => -32_700,
          "message" => "Parse error"
        )
      )
    end

    it "handles protocol errors" do
      allow(server).to receive(:handle_message).and_raise(
        MCPRuby::ProtocolError.new("Protocol error", code: -32_600, request_id: "123")
      )

      input = StringIO.new('{"id": "123", "method": "test"}\n')
      allow($stdin).to receive(:gets).and_return(input.string, nil)

      begin
        transport.run
      rescue EOFError
        # Expected
      end

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

      input = StringIO.new('{"id": "123", "method": "test"}\n')
      allow($stdin).to receive(:gets).and_return(input.string, nil)

      begin
        transport.run
      rescue EOFError
        # Expected
      end

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
