# frozen_string_literal: true

require "spec_helper"

RSpec.describe VectorMCP::Server do
  let(:server_name) { "TestServer" }
  let(:server_version) { "1.0.0" }
  let(:server) { VectorMCP::Server.new(name: server_name, version: server_version) }
  let(:session) do
    VectorMCP::Session.new(server_info: server.server_info, server_capabilities: server.server_capabilities,
                           protocol_version: server.protocol_version)
  end
  let(:session_id) { "test-session-123" }

  before do
    # Mock logger to avoid console output during tests
    # Allow :level= to be called during initialization
    logger_double = instance_double("Logger", info: nil, debug: nil, warn: nil, error: nil)
    allow(logger_double).to receive(:level=) # Allow the level setter
    allow(VectorMCP).to receive(:logger).and_return(logger_double)
    # Simulate initialization for most tests
    allow(session).to receive(:initialized?).and_return(true)
    # Setup the initialize request handler on the session mock itself
    allow(session).to receive(:initialize!).and_return({ capabilities: server.server_capabilities })
  end

  describe "#initialize" do
    it "sets the correct attributes" do
      expect(server.name).to eq(server_name)
      expect(server.version).to eq(server_version)
      expect(server.protocol_version).to eq(VectorMCP::Server::PROTOCOL_VERSION)
      # We don't need to assert the class when it's mocked
      # expect(server.logger).to be_a(Logger)
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

      expect(server.tools[tool_name]).to be_a(VectorMCP::Definitions::Tool)
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

      expect(server.resources[uri]).to be_a(VectorMCP::Definitions::Resource)
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

      expect(server.prompts[name]).to be_a(VectorMCP::Definitions::Prompt)
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
    let(:handler) { proc { |_params, _session, _server| "response" } }

    it "registers a request handler" do
      server.on_request(method, &handler)
      expect(server.instance_variable_get(:@request_handlers)[method]).to eq(handler)
    end
  end

  describe "#on_notification" do
    let(:method) { "test_notification" }
    let(:handler) { proc { |_params, _session, _server| } }

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
    context "before initialization" do
      let(:initialize_message) do
        { "id" => "1", "method" => "initialize", "params" => { "capabilities" => {} } }
      end
      let(:other_message) do
        { "id" => "2", "method" => "ping", "params" => {} }
      end

      before do
        allow(session).to receive(:initialized?).and_return(false)
      end

      it "allows the initialize request" do
        expect(server.handle_message(initialize_message, session, session_id)).to eq({ capabilities: server.server_capabilities })
      end

      it "raises InitializationError for other requests" do
        expect do
          server.handle_message(other_message, session, session_id)
        end.to raise_error(VectorMCP::InitializationError) { |e| expect(e.request_id).to eq("2") }
      end
    end

    context "with a valid request message" do
      let(:request_id) { "123" }
      let(:method) { "test_method" }
      let(:params) { { "key" => "value" } }
      let(:message) { { "id" => request_id, "method" => method, "params" => params } }
      let(:expected_result) { { "data" => "success" } }
      let(:mock_handler) { double("RequestHandler") }

      before do
        allow(mock_handler).to receive(:call).with(params, session, server).and_return(expected_result)
        server.on_request(method, &mock_handler.method(:call))
      end

      it "calls the correct request handler" do
        server.handle_message(message, session, session_id)
        expect(mock_handler).to have_received(:call).with(params, session, server)
      end

      it "returns the result from the handler" do
        result = server.handle_message(message, session, session_id)
        expect(result).to eq(expected_result)
      end

      it "tracks in-flight requests" do
        server.handle_message(message, session, session_id)
        expect(server.in_flight_requests).not_to include(request_id)
      end
    end

    context "with a request for an unknown method" do
      let(:message) { { "id" => "404", "method" => "non_existent_method" } }

      it "raises MethodNotFoundError" do
        expect do
          server.handle_message(message, session, session_id)
        end.to raise_error(VectorMCP::MethodNotFoundError) do |e|
          expect(e.message).to include("non_existent_method")
          expect(e.code).to eq(-32_601)
          expect(e.request_id).to eq("404")
        end
      end
    end

    context "when a request handler raises an expected protocol error" do
      let(:message) { { "id" => "501", "method" => "bad_params_method" } }
      let(:mock_handler) { double("RequestHandler") }

      before do
        allow(mock_handler).to receive(:call).and_raise(VectorMCP::InvalidParamsError.new("Bad param", request_id: "501"))
        server.on_request("bad_params_method", &mock_handler.method(:call))
      end

      it "re-raises the specific protocol error" do
        expect do
          server.handle_message(message, session, session_id)
        end.to raise_error(VectorMCP::InvalidParamsError) do |e|
          expect(e.message).to eq("Bad param")
          expect(e.code).to eq(-32_602)
          expect(e.request_id).to eq("501")
        end
      end
    end

    context "when a request handler raises an unexpected StandardError" do
      let(:message) { { "id" => "500", "method" => "broken_method" } }
      let(:error_message) { "Something broke badly" }
      let(:mock_handler) { double("RequestHandler") }

      before do
        allow(mock_handler).to receive(:call).and_raise(StandardError, error_message)
        server.on_request("broken_method", &mock_handler.method(:call))
      end

      it "raises InternalError with limited details" do
        expect do
          server.handle_message(message, session, session_id)
        end.to raise_error(VectorMCP::InternalError) do |e|
          expect(e.code).to eq(-32_603)
          expect(e.message).to eq("Request handler failed unexpectedly")
          expect(e.request_id).to eq("500")
          # Check that sensitive details are NOT included
          expect(e.details).to eq({ method: "broken_method", error: "An internal error occurred" })
        end
      end

      it "logs the original error" do
        expect(server.logger).to receive(:error).with(/Unhandled error during request 'broken_method': #{error_message}/)
        expect { server.handle_message(message, session, session_id) }.to raise_error(VectorMCP::InternalError)
      end
    end

    context "with tools/call where the tool handler fails" do
      let(:tool_name) { "failing_tool" }
      let(:error_message) { "Tool crashed" }
      let(:message) do
        { "id" => "t1", "method" => "tools/call", "params" => { "name" => tool_name, "arguments" => {} } }
      end

      before do
        failing_handler = proc { raise StandardError, error_message }
        server.register_tool(name: tool_name, description: "fails", input_schema: {}, &failing_handler)
      end

      it "raises InternalError" do
        expect do
          server.handle_message(message, session, session_id)
        end.to raise_error(VectorMCP::InternalError) do |e|
          expect(e.code).to eq(-32_603)
          expect(e.message).to eq("Tool execution failed")
          expect(e.request_id).to eq("t1")
          expect(e.details).to eq({ tool: tool_name, error: error_message })
        end
      end

      it "logs the original tool error" do
        expect(server.logger).to receive(:error).with(/Error executing tool '#{tool_name}': #{error_message}/)
        expect { server.handle_message(message, session, session_id) }.to raise_error(VectorMCP::InternalError)
      end
    end

    context "with resources/read where the resource handler fails" do
      let(:resource_uri) { "crash://resource" }
      let(:error_message) { "Resource exploded" }
      let(:message) do
        { "id" => "r1", "method" => "resources/read", "params" => { "uri" => resource_uri } }
      end

      before do
        failing_handler = proc { raise StandardError, error_message }
        server.register_resource(uri: resource_uri, name: "fails", description: "fails", &failing_handler)
      end

      it "raises InternalError" do
        expect do
          server.handle_message(message, session, session_id)
        end.to raise_error(VectorMCP::InternalError) do |e|
          expect(e.code).to eq(-32_603)
          expect(e.message).to eq("Resource read failed")
          expect(e.request_id).to eq("r1")
          expect(e.details).to eq({ uri: resource_uri, error: error_message })
        end
      end

      it "logs the original resource error" do
        expect(server.logger).to receive(:error).with(/Error reading resource '#{resource_uri}': #{error_message}/)
        expect { server.handle_message(message, session, session_id) }.to raise_error(VectorMCP::InternalError)
      end
    end

    context "with a valid notification message" do
      let(:method) { "test_notification" }
      let(:params) { { "key" => "value" } }
      let(:message) { { "method" => method, "params" => params } }
      let(:mock_handler) { double("NotificationHandler") }

      before do
        allow(mock_handler).to receive(:call).with(params, session, server)
        server.on_notification(method, &mock_handler.method(:call))
      end

      it "calls the correct notification handler" do
        server.handle_message(message, session, session_id)
        expect(mock_handler).to have_received(:call).with(params, session, server)
      end

      it "returns nil" do
        expect(server.handle_message(message, session, session_id)).to be_nil
      end
    end

    context "when a notification handler raises an error" do
      let(:method) { "failing_notification" }
      let(:message) { { "method" => method, "params" => {} } }
      let(:error_message) { "Notification failed" }
      let(:mock_handler) { double("NotificationHandler") }

      before do
        allow(mock_handler).to receive(:call).and_raise(StandardError, error_message)
        server.on_notification(method, &mock_handler.method(:call))
      end

      it "does not raise an error" do
        expect { server.handle_message(message, session, session_id) }.not_to raise_error
      end

      it "logs the error" do
        expect(server.logger).to receive(:error).with(/Error executing notification handler '#{method}': #{error_message}/)
        server.handle_message(message, session, session_id)
      end
    end

    context "when receiving a message with id but no method" do
      let(:message) { { "id" => "456" } }

      it "raises an InvalidRequestError" do
        expect do
          server.handle_message(message, session, session_id)
        end.to raise_error(VectorMCP::InvalidRequestError, /Request object must include a 'method' member/) do |e|
          expect(e.request_id).to eq("456") # Check if ID is captured
        end
      end
    end

    context "with an invalid message (no id, no method)" do
      let(:message) { {} }

      it "raises an InvalidRequestError" do
        expect do
          server.handle_message(message, session, session_id)
        end.to raise_error(VectorMCP::InvalidRequestError, /Invalid message format/) do |e|
          expect(e.request_id).to be_nil
        end
      end
    end

    context "with prompts/get request" do
      let(:prompt_name) { "test_prompt" }
      let(:request_args) { { "arg1" => "value1" } }
      let(:message) do
        {
          "id" => "p1",
          "method" => "prompts/get",
          "params" => { "name" => prompt_name, "arguments" => request_args }
        }
      end
      let(:expected_messages) { [{ role: "user", content: { type: "text", text: "Generated with value1" } }] }
      let(:expected_description) { "Dynamic description for value1" }
      let(:handler_result) { { description: expected_description, messages: expected_messages } }
      let(:mock_prompt_handler) { double("PromptHandler") }

      context "when prompt exists and handler succeeds" do
        before do
          allow(mock_prompt_handler).to receive(:call).with(request_args).and_return(handler_result)
          server.register_prompt(name: prompt_name, description: "Test", arguments: [], &mock_prompt_handler.method(:call))
        end

        it "calls the registered prompt handler with arguments" do
          server.handle_message(message, session, session_id)
          expect(mock_prompt_handler).to have_received(:call).with(request_args)
        end

        it "returns the result from the prompt handler" do
          result = server.handle_message(message, session, session_id)
          expect(result).to eq(handler_result)
          expect(result[:description]).to eq(expected_description)
          expect(result[:messages]).to eq(expected_messages)
        end
      end

      context "when prompt exists but handler returns invalid structure" do
        before do
          allow(mock_prompt_handler).to receive(:call).with(request_args).and_return({ wrong_key: [] }) # Missing :messages
          server.register_prompt(name: prompt_name, description: "Test", arguments: [], &mock_prompt_handler.method(:call))
        end

        it "raises InternalError due to invalid structure" do
          expect do
            server.handle_message(message, session, session_id)
          end.to raise_error(VectorMCP::InternalError) do |e|
            expect(e.code).to eq(-32_603)
            expect(e.message).to eq("Prompt handler returned invalid data structure")
            expect(e.details[:prompt]).to eq(prompt_name)
          end
        end
      end

      context "when prompt exists but handler returns invalid message structure" do
        before do
          invalid_messages = [{ role: "user", content: "just a string" }] # Content should be hash
          allow(mock_prompt_handler).to receive(:call).with(request_args).and_return({ messages: invalid_messages })
          server.register_prompt(name: prompt_name, description: "Test", arguments: [], &mock_prompt_handler.method(:call))
        end

        it "raises InternalError due to invalid message structure" do
          expect do
            server.handle_message(message, session, session_id)
          end.to raise_error(VectorMCP::InternalError) do |e|
            expect(e.code).to eq(-32_603)
            expect(e.message).to eq("Prompt handler returned invalid message structure")
            expect(e.details[:prompt]).to eq(prompt_name)
          end
        end
      end

      context "when prompt exists but handler raises an error" do
        let(:handler_error_message) { "Handler exploded" }
        before do
          allow(mock_prompt_handler).to receive(:call).with(request_args).and_raise(StandardError, handler_error_message)
          server.register_prompt(name: prompt_name, description: "Test", arguments: [], &mock_prompt_handler.method(:call))
        end

        it "raises InternalError" do
          expect do
            server.handle_message(message, session, session_id)
          end.to raise_error(VectorMCP::InternalError) do |e|
            expect(e.code).to eq(-32_603)
            expect(e.message).to eq("Prompt handler failed unexpectedly")
            expect(e.details[:prompt]).to eq(prompt_name)
            expect(e.details[:error]).to eq(handler_error_message) # Include original error message in details
          end
        end

        it "logs the original handler error" do
          expect(server.logger).to receive(:error).with(/Error executing prompt handler for '#{prompt_name}': #{handler_error_message}/)
          expect { server.handle_message(message, session, session_id) }.to raise_error(VectorMCP::InternalError)
        end
      end

      context "when prompt does not exist" do
        let(:message_unknown) { { "id" => "p2", "method" => "prompts/get", "params" => { "name" => "unknown_prompt" } } }
        it "raises NotFoundError" do
          expect do
            server.handle_message(message_unknown, session, session_id)
          end.to raise_error(VectorMCP::NotFoundError) do |e|
            expect(e.code).to eq(-32_001) # Should be the NotFoundError code
            expect(e.message).to include("Prompt not found: unknown_prompt")
          end
        end
      end
    end
  end
end
