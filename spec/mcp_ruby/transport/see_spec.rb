# frozen_string_literal: true

require "spec_helper"
require "rack/test"

RSpec.describe MCPRuby::Transport::SSE do
  include Rack::Test::Methods

  let(:server) { instance_double("MCPRuby::Server") }
  let(:logger) { instance_double("Logger") }
  let(:session) { instance_double("MCPRuby::Session") }
  let(:server_info) { { name: "test", version: "1.0.0" } }
  let(:server_capabilities) { { tools: { listChanged: false } } }
  let(:protocol_version) { "2024-11-05" }
  let(:options) { { host: "localhost", port: 8080, path_prefix: "/mcp-test" } }

  subject(:transport) { described_class.new(server, options) }

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

    # Mock EventMachine and Thin to avoid actually starting the server
    allow(EventMachine).to receive(:run).and_yield
    allow(EventMachine).to receive(:stop)
    allow(Thin::Server).to receive(:start)

    # To simulate the trap behavior without actually trapping signals
    allow(transport).to receive(:trap)
  end

  describe "#initialize" do
    it "sets up the server and logger" do
      expect(transport.server).to eq(server)
      expect(transport.logger).to eq(logger)
    end

    it "uses default values when options are not provided" do
      default_transport = described_class.new(server)
      expect(default_transport.instance_variable_get(:@host)).to eq("localhost")
      expect(default_transport.instance_variable_get(:@port)).to eq(3000)
      expect(default_transport.instance_variable_get(:@path_prefix)).to eq("/mcp")
    end

    it "uses provided options when specified" do
      expect(transport.instance_variable_get(:@host)).to eq(options[:host])
      expect(transport.instance_variable_get(:@port)).to eq(options[:port])
      expect(transport.instance_variable_get(:@path_prefix)).to eq(options[:path_prefix])
    end

    it "initializes empty clients and message queue" do
      expect(transport.instance_variable_get(:@clients)).to eq({})
      expect(transport.instance_variable_get(:@message_queue)).to eq({})
    end
  end

  describe "#run" do
    it "initializes a session" do
      allow(transport).to receive(:build_rack_app).and_return(double("app"))
      allow(transport).to receive(:start_server)

      transport.run

      expect(MCPRuby::Session).to have_received(:new).with(
        server_info: server_info,
        server_capabilities: server_capabilities,
        protocol_version: protocol_version
      )
    end

    it "builds a Rack app and starts the server" do
      app_double = double("rack_app")
      allow(transport).to receive(:build_rack_app).and_return(app_double)
      expect(transport).to receive(:start_server).with(app_double)

      transport.run
    end

    it "logs fatal errors" do
      error = StandardError.new("Test error")
      allow(transport).to receive(:build_rack_app).and_raise(error)
      allow(error).to receive(:backtrace).and_return(%w[line1 line2])

      expect(logger).to receive(:fatal).with(/Fatal error in SSE transport: Test error/)
      expect { transport.run }.to raise_error(SystemExit)
    end
  end

  describe "#send_response" do
    it "creates a properly formatted JSON-RPC response" do
      id = "123"
      result = { value: "test" }

      expect(transport).to receive(:send_message).with(
        jsonrpc: "2.0",
        id: id,
        result: result
      )

      transport.send_response(id, result)
    end
  end

  describe "#build_rack_app" do
    let(:app) do
      transport.send(:build_rack_app, session)
    end

    it "returns a Rack application" do
      expect(app).to be_a(Rack::Builder)
    end

    it "has routes for /mcp/sse and /mcp/message" do
      app = transport.send(:build_rack_app, session)

      # Convert the app to string to check for route mappings
      app_str = app.to_app.inspect
      expect(app_str).to include("/mcp/sse")
      expect(app_str).to include("/mcp/message")
    end
  end

  describe "#start_server" do
    let(:app) { double("rack_app") }

    it "starts Thin server with correct options" do
      expect(Thin::Server).to receive(:start).with("localhost", 8080, app)
      transport.send(:start_server, app)
    end

    it "sets up signal traps" do
      expect(transport).to receive(:trap).with("INT")
      expect(transport).to receive(:trap).with("TERM")

      transport.send(:start_server, app)
    end

    it "logs server start" do
      expect(logger).to receive(:info).with("SSE transport started at http://localhost:8080/mcp-test")
      transport.send(:start_server, app)
    end
  end

  describe "#stop_server" do
    before do
      transport.instance_variable_set(:@clients, {
                                        "client1" => double("client1", close: nil),
                                        "client2" => double("client2", close: nil)
                                      })
    end

    it "closes all client connections" do
      client1 = transport.instance_variable_get(:@clients)["client1"]
      client2 = transport.instance_variable_get(:@clients)["client2"]

      expect(client1).to receive(:close)
      expect(client2).to receive(:close)

      transport.send(:stop_server)
    end

    it "stops the EventMachine loop" do
      expect(EventMachine).to receive(:stop)
      transport.send(:stop_server)
    end

    it "logs shutdown" do
      expect(logger).to receive(:info).with("Stopping SSE transport...")
      transport.send(:stop_server)
    end
  end

  describe "#handle_message" do
    let(:message) { { "id" => "123", "method" => "test", "params" => { "key" => "value" } } }
    let(:client_id) { "client1" }

    before do
      allow(server).to receive(:handle_message).and_return({ status: "handled" })
    end

    it "registers a new client if not already registered" do
      transport.send(:handle_message, message, session, client_id)

      clients = transport.instance_variable_get(:@clients)
      expect(clients).to have_key(client_id)
      expect(clients[client_id][:id]).to eq(client_id)
    end

    it "forwards the message to the server" do
      expect(server).to receive(:handle_message).with(message, session, transport)

      transport.send(:handle_message, message, session, client_id)
    end

    it "queues the response for SSE delivery" do
      response = { key: "value" }
      allow(server).to receive(:handle_message).and_return(response)

      transport.send(:handle_message, message, session, client_id)

      queue = transport.instance_variable_get(:@message_queue)
      expect(queue[client_id]).to include(response)
    end

    it "handles protocol errors" do
      error = MCPRuby::ProtocolError.new("Protocol error", code: -32_600, request_id: "123", details: { error: "details" })
      allow(server).to receive(:handle_message).and_raise(error)

      result = transport.send(:handle_message, message, session, client_id)

      expect(result).to include(
        jsonrpc: "2.0",
        id: "123",
        error: {
          code: -32_600,
          message: "Protocol error",
          data: { error: "details" }
        }
      )
    end

    it "handles standard errors" do
      error = StandardError.new("Standard error")
      allow(server).to receive(:handle_message).and_raise(error)
      allow(error).to receive(:backtrace).and_return(%w[line1 line2])

      result = transport.send(:handle_message, message, session, client_id)

      expect(result).to include(
        jsonrpc: "2.0",
        id: "123",
        error: {
          code: -32_603,
          message: "Internal server error",
          data: { details: "Standard error" }
        }
      )
    end
  end

  describe "#send_message" do
    let(:message) { { id: "123", result: "success" } }

    before do
      client1 = double("client1")
      client2 = double("client2")
      allow(client1).to receive(:write)
      allow(client2).to receive(:write)

      transport.instance_variable_set(:@clients, {
                                        "client1" => client1,
                                        "client2" => client2
                                      })
    end

    it "logs the message" do
      expect(logger).to receive(:debug)
      transport.send(:send_message, message)
    end

    it "sends the message to all connected clients" do
      client1 = transport.instance_variable_get(:@clients)["client1"]
      client2 = transport.instance_variable_get(:@clients)["client2"]

      expect(client1).to receive(:write).with(/data: .*"id":"123".*"result":"success"/)
      expect(client2).to receive(:write).with(/data: .*"id":"123".*"result":"success"/)

      transport.send(:send_message, message)
    end

    it "handles errors when sending to clients" do
      client1 = transport.instance_variable_get(:@clients)["client1"]
      allow(client1).to receive(:write).and_raise(StandardError.new("Connection error"))

      expect(logger).to receive(:error).with(/Error sending to client client1: Connection error/)
      transport.send(:send_message, message)

      # Client should be removed
      expect(transport.instance_variable_get(:@clients)).not_to have_key("client1")
    end
  end

  describe "#send_notification" do
    it "creates a properly formatted JSON-RPC notification" do
      method = "notification"
      params = { key: "value" }

      expect(transport).to receive(:send_message).with(
        jsonrpc: "2.0",
        method: method,
        params: params
      )

      transport.send(:send_notification, method, params)
    end

    it "omits params if not provided" do
      method = "notification"

      expect(transport).to receive(:send_message).with(
        jsonrpc: "2.0",
        method: method
      )

      transport.send(:send_notification, method)
    end
  end

  describe "#send_error" do
    it "creates a properly formatted JSON-RPC error response" do
      id = "123"
      code = -32_600
      message = "Invalid request"
      data = { details: "error details" }

      expect(transport).to receive(:send_message).with(
        jsonrpc: "2.0",
        id: id,
        error: {
          code: code,
          message: message,
          data: data
        }
      )

      transport.send(:send_error, id, code, message, data)
    end

    it "omits data if not provided" do
      id = "123"
      code = -32_600
      message = "Invalid request"

      expect(transport).to receive(:send_message).with(
        jsonrpc: "2.0",
        id: id,
        error: {
          code: code,
          message: message
        }
      )

      transport.send(:send_error, id, code, message, nil)
    end
  end

  describe MCPRuby::Transport::SSE::SSEStream do
    let(:client_id) { "test-client" }
    let(:transport) { double("transport") }

    subject(:stream) { described_class.new(client_id, transport) }

    before do
      allow(transport).to receive(:instance_variable_get).with(:@clients).and_return({})
    end

    describe "#initialize" do
      it "sets the client id and transport" do
        expect(stream.instance_variable_get(:@client_id)).to eq(client_id)
        expect(stream.instance_variable_get(:@transport)).to eq(transport)
      end

      it "initializes as not closed" do
        expect(stream.instance_variable_get(:@closed)).to be false
      end
    end

    describe "#each" do
      it "yields initial headers" do
        clients = {}
        allow(transport).to receive(:instance_variable_get).and_return(clients)

        # Mock sleep to avoid waiting in test
        allow(stream).to receive(:sleep)
        # Force loop to execute only once
        allow(stream).to receive(:loop) do |&block|
          # Run once then mark as closed
          block.call
          stream.instance_variable_set(:@closed, true)
          block.call # Run again to test break condition
        end

        expect { |b| stream.each(&b) }.to yield_successive_args(
          "retry: 10000\n\n",
          ": keep-alive\n\n"
        )
      end

      it "registers the client with the transport" do
        clients = {}
        allow(transport).to receive(:instance_variable_get).and_return(clients)
        allow(stream).to receive(:sleep)
        allow(stream).to receive(:loop) do |&block|
          stream.instance_variable_set(:@closed, true)
        end

        stream.each { |_| }

        expect(clients[client_id]).to eq(stream)
      end
    end

    describe "#write" do
      it "yields data when not closed" do
        data = "data: test\n\n"

        expect { |b| stream.write(data, &b) }.to yield_with_args(data)
      end

      it "does not yield data when closed" do
        stream.instance_variable_set(:@closed, true)
        data = "data: test\n\n"

        expect { |b| stream.write(data, &b) }.not_to yield_control
      end
    end

    describe "#close" do
      it "marks the stream as closed" do
        expect(stream.instance_variable_get(:@closed)).to be false
        stream.close
        expect(stream.instance_variable_get(:@closed)).to be true
      end
    end
  end
end
