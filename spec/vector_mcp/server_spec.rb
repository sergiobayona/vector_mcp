# frozen_string_literal: true

require "spec_helper"

RSpec.describe VectorMCP::Server do
  let(:server_name) { "TestServer" }
  let(:server_version) { "1.0.0" }
  let(:server) { VectorMCP::Server.new(name: server_name, version: server_version) }
  let(:session) do
    VectorMCP::Session.new(server)
  end
  let(:session_id) { "test-session-123" }

  before do
    # Mock logger to avoid console output during tests
    # Allow :level= to be called during initialization
    logger_double = instance_double("Logger", info: nil, debug: nil, warn: nil, error: nil, fatal: nil)
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

    it "allows positional name argument" do
      positional_server = VectorMCP::Server.new("PositionalServer", version: server_version)
      expect(positional_server.name).to eq("PositionalServer")
      expect(positional_server.version).to eq(server_version)
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
    let(:arguments) { [{ name: "arg1" }, { name: "arg2" }] }
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

    describe "register_prompt argument validation" do
      it "raises error for invalid argument schema" do
        expect do
          server.register_prompt(name: "bad", description: "d", arguments: ["wrong"]) { "x" }
        end.to raise_error(ArgumentError, /must be a Hash/)
      end

      it "raises error for missing name" do
        expect do
          server.register_prompt(name: "bad", description: "d", arguments: [{}]) { "x" }
        end.to raise_error(ArgumentError, /missing :name/)
      end

      it "raises error on unknown keys" do
        expect do
          server.register_prompt(name: "bad", description: "d", arguments: [{ name: "a", foo: 1 }]) { "x" }
        end.to raise_error(ArgumentError, /unknown keys/)
      end
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
      it "returns default sampling capabilities" do
        capabilities = server.server_capabilities
        expected_sampling_caps = {
          methods: ["createMessage"],
          features: {
            modelPreferences: true
          },
          limits: {
            defaultTimeout: 30
          },
          contextInclusion: %w[none thisServer]
        }
        expect(capabilities).to eq({ sampling: expected_sampling_caps })
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
        expect(capabilities[:sampling]).to include(:methods, :features, :limits, :contextInclusion)
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
        expect(capabilities[:sampling]).to include(:methods, :features, :limits, :contextInclusion)
      end
    end

    context "when prompts are registered" do
      before do
        server.register_prompt(
          name: "test_prompt",
          description: "test",
          arguments: [{ name: "arg1" }],
          &proc { "response" }
        )
      end

      it "sets listChanged to true after registration" do
        capabilities = server.server_capabilities
        expect(capabilities[:prompts]).to eq({ listChanged: true })
      end

      it "resets listChanged to false after prompts/list" do
        # Trigger list_prompts handler via Core directly
        VectorMCP::Handlers::Core.list_prompts({}, session, server)
        capabilities = server.server_capabilities
        expect(capabilities[:prompts]).to eq({ listChanged: false })
      end
    end
  end

  describe "sampling capabilities configuration" do
    context "with default configuration" do
      it "provides basic sampling capabilities" do
        capabilities = server.server_capabilities[:sampling]

        expect(capabilities[:methods]).to eq(["createMessage"])
        expect(capabilities[:features][:modelPreferences]).to be true
        expect(capabilities[:limits][:defaultTimeout]).to eq(30)
        expect(capabilities[:contextInclusion]).to eq(%w[none thisServer])

        # Features that are disabled by default should not be present
        expect(capabilities[:features]).not_to have_key(:streaming)
        expect(capabilities[:features]).not_to have_key(:toolCalls)
        expect(capabilities[:features]).not_to have_key(:images)
      end

      it "returns sampling config through accessor" do
        config = server.sampling_config

        expect(config[:enabled]).to be true
        expect(config[:methods]).to eq(["createMessage"])
        expect(config[:supports_streaming]).to be false
        expect(config[:supports_tool_calls]).to be false
        expect(config[:supports_images]).to be false
        expect(config[:max_tokens_limit]).to be_nil
        expect(config[:timeout_seconds]).to eq(30)
        expect(config[:context_inclusion_methods]).to eq(%w[none thisServer])
        expect(config[:model_preferences_supported]).to be true
      end
    end

    context "with custom configuration enabling advanced features" do
      let(:custom_config) do
        {
          supports_streaming: true,
          supports_tool_calls: true,
          supports_images: true,
          max_tokens_limit: 4000,
          timeout_seconds: 60,
          context_inclusion_methods: %w[none thisServer allServers],
          model_preferences_supported: false
        }
      end

      let(:enhanced_server) do
        VectorMCP::Server.new(
          name: "EnhancedSamplingServer",
          version: "1.0.0",
          sampling_config: custom_config
        )
      end

      it "provides enhanced sampling capabilities" do
        capabilities = enhanced_server.server_capabilities[:sampling]

        expect(capabilities[:methods]).to eq(["createMessage"])
        expect(capabilities[:features][:streaming]).to be true
        expect(capabilities[:features][:toolCalls]).to be true
        expect(capabilities[:features][:images]).to be true
        expect(capabilities[:features]).not_to have_key(:modelPreferences)
        expect(capabilities[:limits][:maxTokens]).to eq(4000)
        expect(capabilities[:limits][:defaultTimeout]).to eq(60)
        expect(capabilities[:contextInclusion]).to eq(%w[none thisServer allServers])
      end

      it "returns enhanced config through accessor" do
        config = enhanced_server.sampling_config

        expect(config[:supports_streaming]).to be true
        expect(config[:supports_tool_calls]).to be true
        expect(config[:supports_images]).to be true
        expect(config[:max_tokens_limit]).to eq(4000)
        expect(config[:timeout_seconds]).to eq(60)
        expect(config[:context_inclusion_methods]).to eq(%w[none thisServer allServers])
        expect(config[:model_preferences_supported]).to be false
      end
    end

    context "with sampling disabled" do
      let(:disabled_server) do
        VectorMCP::Server.new(
          name: "DisabledSamplingServer",
          sampling_config: { enabled: false }
        )
      end

      it "provides empty sampling capabilities" do
        capabilities = disabled_server.server_capabilities[:sampling]
        expect(capabilities).to eq({})
      end

      it "shows disabled in config" do
        config = disabled_server.sampling_config
        expect(config[:enabled]).to be false
      end
    end

    context "with minimal configuration" do
      let(:minimal_config) do
        {
          max_tokens_limit: 1000,
          supports_streaming: true
        }
      end

      let(:minimal_server) do
        VectorMCP::Server.new(
          name: "MinimalSamplingServer",
          sampling_config: minimal_config
        )
      end

      it "merges with defaults correctly" do
        capabilities = minimal_server.server_capabilities[:sampling]

        # Custom values
        expect(capabilities[:limits][:maxTokens]).to eq(1000)
        expect(capabilities[:features][:streaming]).to be true

        # Default values preserved
        expect(capabilities[:methods]).to eq(["createMessage"])
        expect(capabilities[:features][:modelPreferences]).to be true
        expect(capabilities[:limits][:defaultTimeout]).to eq(30)
        expect(capabilities[:contextInclusion]).to eq(%w[none thisServer])

        # Defaults for disabled features
        expect(capabilities[:features]).not_to have_key(:toolCalls)
        expect(capabilities[:features]).not_to have_key(:images)
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
        # Use match to check the beginning of the log message including the ID,
        # ignoring the potentially long backtrace.
        log_pattern = /Unhandled error during request '#{message["method"]}' \(ID: #{message["id"]}\): #{error_message}/
        expect(server.logger).to receive(:error).with(match(log_pattern))
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
          # Error now caught by the generic handler in Server#handle_request
          expect(e.message).to eq("Request handler failed unexpectedly")
          expect(e.request_id).to eq("t1")
          # Details are now less specific from the generic handler
          expect(e.details).to eq({ method: message["method"], error: "An internal error occurred" })
        end
      end

      it "logs the original tool error" do
        # Expect the log message from the generic handler in Server#handle_request
        log_pattern = /Unhandled error during request '#{message["method"]}' \(ID: #{message["id"]}\): #{error_message}/
        expect(server.logger).to receive(:error).with(match(log_pattern))
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
          # Error now caught by the generic handler in Server#handle_request
          expect(e.message).to eq("Request handler failed unexpectedly")
          expect(e.request_id).to eq("r1")
          # Details are now less specific from the generic handler
          expect(e.details).to eq({ method: message["method"], error: "An internal error occurred" })
        end
      end

      it "logs the original resource error" do
        # Expect the log message from the generic handler in Server#handle_request
        log_pattern = /Unhandled error during request '#{message["method"]}' \(ID: #{message["id"]}\): #{error_message}/
        expect(server.logger).to receive(:error).with(match(log_pattern))
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
          server.register_prompt(name: prompt_name, description: "Test", arguments: [{ name: "arg1" }], &mock_prompt_handler.method(:call))
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
          server.register_prompt(name: prompt_name, description: "Test", arguments: [{ name: "arg1" }], &mock_prompt_handler.method(:call))
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
          server.register_prompt(name: prompt_name, description: "Test", arguments: [{ name: "arg1" }], &mock_prompt_handler.method(:call))
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
          server.register_prompt(name: prompt_name, description: "Test", arguments: [{ name: "arg1" }], &mock_prompt_handler.method(:call))
        end

        it "raises InternalError" do
          expect do
            server.handle_message(message, session, session_id)
          end.to raise_error(VectorMCP::InternalError) do |e|
            expect(e.code).to eq(-32_603)
            # Error now caught by the generic handler in Server#handle_request
            expect(e.message).to eq("Request handler failed unexpectedly")
            # Details are now less specific from the generic handler
            expect(e.details).to eq({ method: message["method"], error: "An internal error occurred" })
          end
        end

        it "logs the original handler error" do
          # Expect the log message from the generic handler in Server#handle_request
          log_pattern = /Unhandled error during request '#{message["method"]}' \(ID: #{message["id"]}\): #{handler_error_message}/
          expect(server.logger).to receive(:error).with(match(log_pattern))
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
            # Check the details attribute for the specific message
            expect(e.details).to include("Prompt not found: unknown_prompt")
          end
        end
      end
    end
  end

  describe "#run" do
    context "with an unsupported transport" do
      it "raises ArgumentError" do
        expect do
          server.run(transport: :unsupported)
        end.to raise_error(ArgumentError, /Unsupported transport/)
      end
    end

    context "with :sse transport" do
      it "exits when SSE dependencies are missing" do
        expect do
          server.run(transport: :sse, options: { host: "localhost" })
        end.to raise_error(SystemExit)
      end
    end
  end

  describe "#handle_request error wrapping" do
    let(:request_id) { "wrap-1" }
    let(:method_name) { "failing_not_found" }
    let(:message) { { "id" => request_id, "method" => method_name, "params" => {} } }

    before do
      # Register a handler that raises NotFoundError WITHOUT request_id to verify wrapping
      server.on_request(method_name) do |_params, _sess, _srv|
        raise VectorMCP::NotFoundError.new("Missing", details: "nothing here")
      end
    end

    it "re-raises the protocol error with the correct request_id" do
      expect do
        server.handle_message(message, session, session_id)
      end.to raise_error(VectorMCP::NotFoundError) { |err| expect(err.request_id).to eq(request_id) }
    end
  end

  describe "#setup_default_handlers" do
    let(:request_handlers) { server.instance_variable_get(:@request_handlers) }
    let(:notification_handlers) { server.instance_variable_get(:@notification_handlers) }

    it "registers all core request handlers" do
      expected_requests = %w[
        ping
        tools/list
        tools/call
        resources/list
        resources/read
        prompts/list
        prompts/get
        prompts/subscribe
      ]
      expect(request_handlers.keys).to include(*expected_requests)
    end

    it "registers all core notification handlers including cancel aliases" do
      expected_notifications = %w[
        initialized
        $/cancelRequest
        $/cancel
        notifications/cancelled
      ]
      expect(notification_handlers.keys).to include(*expected_notifications)
    end

    it "maps ping handler to Handlers::Core.ping" do
      handler = request_handlers["ping"]
      # Call the proc and ensure it returns the same result as Handlers::Core.ping
      expect(handler.call({}, session, server)).to eq(VectorMCP::Handlers::Core.ping({}, session, server))
    end
  end

  describe "dynamic prompt list change notifications" do
    let(:stdio_transport) { instance_double(VectorMCP::Transport::Stdio, send_notification: nil) }

    before do
      server.transport = stdio_transport
    end

    it "sends notifications/prompts/list_changed via stdio transport" do
      server.register_prompt(name: "notify_prompt", description: "d", arguments: []) { "resp" }
      expect(stdio_transport).to have_received(:send_notification).with("notifications/prompts/list_changed")
    end
  end

  describe "#roots" do
    it "is initially empty" do
      expect(server.roots).to be_empty
    end
  end

  describe "#register_root" do
    let(:test_dir) { Dir.mktmpdir }

    after { FileUtils.rm_rf(test_dir) }

    it "registers a root with valid URI and name" do
      uri = "file://#{test_dir}"
      name = "Test Project"

      result = server.register_root(uri: uri, name: name)

      expect(result).to eq(server) # Returns self for chaining
      expect(server.roots).to have_key(uri)

      root = server.roots[uri]
      expect(root.uri).to eq(uri)
      expect(root.name).to eq(name)
    end

    it "validates the root during registration" do
      invalid_uri = "file:///non/existent/path"

      expect do
        server.register_root(uri: invalid_uri, name: "Invalid")
      end.to raise_error(ArgumentError, /Root directory does not exist/)
    end

    it "prevents duplicate registration" do
      uri = "file://#{test_dir}"

      server.register_root(uri: uri, name: "First")

      expect do
        server.register_root(uri: uri, name: "Second")
      end.to raise_error(ArgumentError, /Root '#{Regexp.escape(uri)}' already registered/)
    end

    it "sets the roots_list_changed flag" do
      # Reset flag first
      server.instance_variable_set(:@roots_list_changed, false)

      server.register_root(uri: "file://#{test_dir}", name: "Test")

      expect(server.instance_variable_get(:@roots_list_changed)).to be true
    end

    it "can chain registrations" do
      subdir1 = File.join(test_dir, "project1")
      subdir2 = File.join(test_dir, "project2")
      Dir.mkdir(subdir1)
      Dir.mkdir(subdir2)

      result = server.register_root(uri: "file://#{subdir1}", name: "Project 1")
                     .register_root(uri: "file://#{subdir2}", name: "Project 2")

      expect(result).to eq(server)
      expect(server.roots).to have_key("file://#{subdir1}")
      expect(server.roots).to have_key("file://#{subdir2}")
    end
  end

  describe "#register_root_from_path" do
    let(:test_dir) { Dir.mktmpdir }

    after { FileUtils.rm_rf(test_dir) }

    it "registers a root from a directory path" do
      name = "Test Project"

      result = server.register_root_from_path(test_dir, name: name)

      expect(result).to eq(server)

      expected_uri = "file://#{test_dir}"
      expect(server.roots).to have_key(expected_uri)

      root = server.roots[expected_uri]
      expect(root.name).to eq(name)
    end

    it "generates name from directory basename when not provided" do
      subdir = File.join(test_dir, "my_project")
      Dir.mkdir(subdir)

      server.register_root_from_path(subdir)

      expected_uri = "file://#{subdir}"
      root = server.roots[expected_uri]
      expect(root.name).to eq("my_project")
    end

    it "expands relative paths" do
      original_dir = Dir.pwd
      Dir.chdir(test_dir)

      begin
        server.register_root_from_path(".", name: "Current")

        # Use realpath to handle symlinks like /var -> /private/var on macOS
        expected_uri = "file://#{File.realpath(test_dir)}"
        expect(server.roots).to have_key(expected_uri)
      ensure
        Dir.chdir(original_dir)
      end
    end
  end

  describe "#server_capabilities" do
    let(:test_dir) { Dir.mktmpdir }

    after { FileUtils.rm_rf(test_dir) }

    it "includes roots capability when roots are registered" do
      server.register_root(uri: "file://#{test_dir}", name: "Test")

      capabilities = server.server_capabilities

      expect(capabilities).to have_key(:roots)
      expect(capabilities[:roots]).to eq({ listChanged: true })
    end

    it "does not include roots capability when no roots are registered" do
      capabilities = server.server_capabilities

      expect(capabilities).not_to have_key(:roots)
    end
  end

  describe "#clear_roots_list_changed" do
    it "resets the roots_list_changed flag" do
      server.instance_variable_set(:@roots_list_changed, true)

      server.clear_roots_list_changed

      expect(server.instance_variable_get(:@roots_list_changed)).to be false
    end
  end

  describe "#notify_roots_list_changed" do
    let(:test_dir) { Dir.mktmpdir }
    let(:mock_transport) { double("transport") }

    after { FileUtils.rm_rf(test_dir) }

    before do
      server.transport = mock_transport
      server.register_root(uri: "file://#{test_dir}", name: "Test")
    end

    it "broadcasts notification when transport supports it" do
      allow(mock_transport).to receive(:respond_to?).with(:broadcast_notification).and_return(true)
      allow(mock_transport).to receive(:respond_to?).with(:send_notification).and_return(false)

      expect(mock_transport).to receive(:broadcast_notification)
        .with("notifications/roots/list_changed")

      server.notify_roots_list_changed
    end

    it "sends notification when transport supports it (fallback)" do
      allow(mock_transport).to receive(:respond_to?).with(:broadcast_notification).and_return(false)
      allow(mock_transport).to receive(:respond_to?).with(:send_notification).and_return(true)

      expect(mock_transport).to receive(:send_notification)
        .with("notifications/roots/list_changed")

      server.notify_roots_list_changed
    end

    it "logs warning when transport doesn't support notifications" do
      allow(mock_transport).to receive(:respond_to?).with(:broadcast_notification).and_return(false)
      allow(mock_transport).to receive(:respond_to?).with(:send_notification).and_return(false)

      expect(server.logger).to receive(:warn)
        .with(%r{Transport does not support sending notifications/roots/list_changed})

      server.notify_roots_list_changed
    end

    it "does nothing when no transport is set" do
      server.transport = nil

      expect { server.notify_roots_list_changed }.not_to raise_error
    end

    it "does nothing when roots_list_changed is false" do
      server.instance_variable_set(:@roots_list_changed, false)

      expect(mock_transport).not_to receive(:broadcast_notification)
      expect(mock_transport).not_to receive(:send_notification)

      server.notify_roots_list_changed
    end
  end
end
