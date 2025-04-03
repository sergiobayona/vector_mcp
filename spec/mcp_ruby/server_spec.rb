# frozen_string_literal: true

require "spec_helper"

RSpec.describe MCPRuby::Server do
  let(:server_name) { "TestServer" }
  let(:server_version) { "1.0.0" }
  let(:server) { MCPRuby::Server.new(name: server_name, version: server_version) }

  describe "#initialize" do
    it "sets the correct attributes" do
      expect(server.name).to eq(server_name)
      expect(server.version).to eq(server_version)
      expect(server.protocol_version).to eq(MCPRuby::Server::PROTOCOL_VERSION)
      expect(server.logger).to be_a(Logger)
    end

    it "initializes empty collections" do
      expect(server.tools).to be_empty
      expect(server.resources).to be_empty
      expect(server.prompts).to be_empty
      expect(server.in_flight_requests).to be_empty
    end
  end

  describe "#register_tool" do
    let(:tool_name) { "test_tool" }
    let(:tool_description) { "A test tool" }
    let(:input_schema) { { type: "object" } }
    let(:handler) { proc { |_params| "result" } }

    it "registers a new tool" do
      server.register_tool(
        name: tool_name,
        description: tool_description,
        input_schema: input_schema,
        &handler
      )

      expect(server.tools[tool_name]).to be_a(MCPRuby::Definitions::Tool)
      expect(server.tools[tool_name].name).to eq(tool_name)
      expect(server.tools[tool_name].description).to eq(tool_description)
    end

    it "raises an error when registering a duplicate tool" do
      server.register_tool(
        name: tool_name,
        description: tool_description,
        input_schema: input_schema,
        &handler
      )

      expect do
        server.register_tool(
          name: tool_name,
          description: tool_description,
          input_schema: input_schema,
          &handler
        )
      end.to raise_error(ArgumentError, "Tool '#{tool_name}' already registered")
    end
  end

  describe "#register_resource" do
    let(:uri) { "test://resource" }
    let(:name) { "Test Resource" }
    let(:description) { "A test resource" }
    let(:mime_type) { "text/plain" }
    let(:handler) { proc { |_params| "content" } }

    it "registers a new resource" do
      server.register_resource(
        uri: uri,
        name: name,
        description: description,
        mime_type: mime_type,
        &handler
      )

      expect(server.resources[uri]).to be_a(MCPRuby::Definitions::Resource)
      expect(server.resources[uri].uri).to eq(uri)
      expect(server.resources[uri].name).to eq(name)
    end

    it "raises an error when registering a duplicate resource" do
      server.register_resource(
        uri: uri,
        name: name,
        description: description,
        mime_type: mime_type,
        &handler
      )

      expect do
        server.register_resource(
          uri: uri,
          name: name,
          description: description,
          mime_type: mime_type,
          &handler
        )
      end.to raise_error(ArgumentError, "Resource '#{uri}' already registered")
    end
  end

  describe "#register_prompt" do
    let(:name) { "test_prompt" }
    let(:description) { "A test prompt" }
    let(:arguments) { %w[arg1 arg2] }
    let(:handler) { proc { |_params| "response" } }

    it "registers a new prompt" do
      server.register_prompt(
        name: name,
        description: description,
        arguments: arguments,
        &handler
      )

      expect(server.prompts[name]).to be_a(MCPRuby::Definitions::Prompt)
      expect(server.prompts[name].name).to eq(name)
      expect(server.prompts[name].description).to eq(description)
    end

    it "raises an error when registering a duplicate prompt" do
      server.register_prompt(
        name: name,
        description: description,
        arguments: arguments,
        &handler
      )

      expect do
        server.register_prompt(
          name: name,
          description: description,
          arguments: arguments,
          &handler
        )
      end.to raise_error(ArgumentError, "Prompt '#{name}' already registered")
    end
  end

  describe "#on_request" do
    let(:method) { "test_method" }
    let(:handler) { proc { |_params| "response" } }

    it "registers a request handler" do
      server.on_request(method, &handler)
      expect(server.instance_variable_get(:@request_handlers)[method]).to eq(handler)
    end
  end

  describe "#on_notification" do
    let(:method) { "test_notification" }
    let(:handler) { proc { |_params| } }

    it "registers a notification handler" do
      server.on_notification(method, &handler)
      expect(server.instance_variable_get(:@notification_handlers)[method]).to eq(handler)
    end
  end

  describe "#server_info" do
    it "returns the correct server information" do
      info = server.server_info
      expect(info[:name]).to eq(server_name)
      expect(info[:version]).to eq(server_version)
    end
  end

  describe "#server_capabilities" do
    context "when no tools, resources, or prompts are registered" do
      it "returns empty capabilities" do
        capabilities = server.server_capabilities
        expect(capabilities).to eq({ experimental: {} })
      end
    end

    context "when tools are registered" do
      before do
        server.register_tool(
          name: "test_tool",
          description: "test",
          input_schema: { type: "object" },
          &proc { "result" }
        )
      end

      it "includes tools capability" do
        capabilities = server.server_capabilities
        expect(capabilities[:tools]).to eq({ listChanged: false })
      end
    end

    context "when resources are registered" do
      before do
        server.register_resource(
          uri: "test://resource",
          name: "test",
          description: "test",
          &proc { "content" }
        )
      end

      it "includes resources capability" do
        capabilities = server.server_capabilities
        expect(capabilities[:resources]).to eq({ subscribe: false, listChanged: false })
      end
    end

    context "when prompts are registered" do
      before do
        server.register_prompt(
          name: "test_prompt",
          description: "test",
          arguments: [],
          &proc { "response" }
        )
      end

      it "includes prompts capability" do
        capabilities = server.server_capabilities
        expect(capabilities[:prompts]).to eq({ listChanged: false })
      end
    end
  end

  describe "#handle_message" do
    let(:session) { instance_double("MCPRuby::Session") }
    let(:transport) { instance_double("MCPRuby::Transport::Stdio") }

    context "with a valid request message" do
      let(:message) do
        {
          "id" => "123",
          "method" => "test_method",
          "params" => { "key" => "value" }
        }
      end

      before do
        allow(session).to receive(:initialized?).and_return(true)
        # Allow the private method to be called
        transport.instance_eval { def send_response(*args); end }
        allow(transport).to receive(:send_response).with(any_args)
        server.on_request("test_method") { |params| params }
      end

      it "processes the request and sends a response" do
        expect(transport).to receive(:send_response).with("123", { "key" => "value" })
        server.handle_message(message, session, transport)
      end
    end

    context "with a valid notification message" do
      let(:message) do
        {
          "method" => "test_notification",
          "params" => { "key" => "value" }
        }
      end

      before do
        allow(session).to receive(:initialized?).and_return(true)
        server.on_notification("test_notification") { |params| params }
      end

      it "processes the notification" do
        expect { server.handle_message(message, session, transport) }.not_to raise_error
      end
    end

    context "with an invalid message" do
      let(:message) { {} }

      it "raises an InvalidRequestError" do
        expect do
          server.handle_message(message, session, transport)
        end.to raise_error(MCPRuby::InvalidRequestError)
      end
    end
  end
end
