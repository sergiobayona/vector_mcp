# frozen_string_literal: true

require "spec_helper"
require "vector_mcp/handlers/core"

RSpec.describe VectorMCP::Handlers::Core do
  let(:logger) { instance_double(Logger, debug: nil, info: nil, error: nil) }
  let(:session) { double("session") }
  let(:server) do
    # Default empty registries
    tools = {}
    resources = {}
    prompts = {}
    double("server", tools: tools, resources: resources, prompts: prompts, logger: logger)
  end

  before do
    # Stub global logger for methods using VectorMCP.logger
    allow(VectorMCP).to receive(:logger).and_return(logger)
    allow(logger).to receive(:level=)
  end

  describe ".ping" do
    it "returns an empty hash" do
      result = described_class.ping({}, session, server)
      expect(result).to eq({})
      expect(logger).to have_received(:debug).with("Handling ping request")
    end
  end

  describe ".list_tools" do
    it "lists all registered tool definitions" do
      tool1 = double("tool1", as_mcp_definition: { "name" => "t1" })
      tool2 = double("tool2", as_mcp_definition: { "name" => "t2" })
      server.tools.merge!("t1" => tool1, "t2" => tool2)

      result = described_class.list_tools({}, session, server)
      expect(result).to eq({ tools: [{ "name" => "t1" }, { "name" => "t2" }] })
    end
  end

  describe ".call_tool" do
    let(:tool) { double("tool", handler: handler) }
    let(:handler) { proc { |_args| "raw_result" } }

    before do
      server.tools["my_tool"] = tool
      allow(VectorMCP::Util).to receive(:convert_to_mcp_content).with("raw_result").and_return(["converted"])
    end

    context "when tool exists" do
      it "calls the handler and wraps result" do
        params = { "name" => "my_tool", "arguments" => { "foo" => "bar" } }
        result = described_class.call_tool(params, session, server)
        expect(result).to eq({ isError: false, content: ["converted"] })
      end

      it "defaults arguments to empty hash" do
        params = { "name" => "my_tool" }
        expect { described_class.call_tool(params, session, server) }.not_to raise_error
      end
    end

    context "when tool is not registered" do
      it "raises NotFoundError with proper details" do
        expect do
          described_class.call_tool({ "name" => "unknown" }, session, server)
        end.to raise_error(VectorMCP::NotFoundError) { |err|
          expect(err.message).to eq("Not Found")
          expect(err.details).to eq("Tool not found: unknown")
        }
      end
    end
  end

  describe ".list_resources" do
    it "lists all registered resource definitions" do
      res1 = double("r1", as_mcp_definition: { "uri" => "u1" })
      res2 = double("r2", as_mcp_definition: { "uri" => "u2" })
      server.resources.merge!("u1" => res1, "u2" => res2)

      result = described_class.list_resources({}, session, server)
      expect(result).to eq({ resources: [{ "uri" => "u1" }, { "uri" => "u2" }] })
    end
  end

  describe ".read_resource" do
    let(:uri) { "memory://r" }
    let(:raw_content) { [{ type: "text", text: "hi" }] }
    let(:converted) { [{ type: "text", text: "hi", mimeType: "text/plain" }] }
    let(:resource) { double("resource", handler: proc { raw_content }, mime_type: "text/plain") }

    before do
      server.resources[uri] = resource
      allow(VectorMCP::Util).to receive(:convert_to_mcp_content).with(raw_content, mime_type: "text/plain").and_return(converted)
    end

    context "when resource exists" do
      it "reads and returns contents with uri added" do
        params = { "uri" => uri }
        result = described_class.read_resource(params, session, server)
        expect(result).to eq({ contents: [{ type: "text", text: "hi", mimeType: "text/plain", uri: uri }] })
      end

      it "preserves existing uri keys in content items" do
        with_uri = [{ type: "text", text: "hi", uri: "override" }]
        # Stub handler to return content items already including uri
        allow(resource).to receive(:handler).and_return(->(_params) { with_uri })
        # Stub conversion to pass through same items (with uri present)
        allow(VectorMCP::Util).to receive(:convert_to_mcp_content).with(with_uri, mime_type: "text/plain").and_return(with_uri)

        result = described_class.read_resource({ "uri" => uri }, session, server)
        expect(result[:contents].first[:uri]).to eq("override")
      end
    end

    context "when resource is not registered" do
      it "raises NotFoundError with proper details" do
        expect do
          described_class.read_resource({ "uri" => "unknown" }, session, server)
        end.to raise_error(VectorMCP::NotFoundError) { |err|
          expect(err.message).to eq("Not Found")
          expect(err.details).to eq("Resource not found: unknown")
        }
      end
    end
  end

  describe ".list_prompts" do
    it "lists all registered prompt definitions" do
      p1 = double("p1", as_mcp_definition: { "name" => "a" })
      p2 = double("p2", as_mcp_definition: { "name" => "b" })
      server.prompts.merge!("a" => p1, "b" => p2)

      result = described_class.list_prompts({}, session, server)
      expect(result).to eq({ prompts: [{ "name" => "a" }, { "name" => "b" }] })
    end
  end

  describe ".list_roots" do
    let(:roots) { {} }
    let(:server) do
      double("server",
             tools: {},
             resources: {},
             prompts: {},
             roots: roots,
             logger: logger)
    end

    before do
      allow(server).to receive(:respond_to?).with(:clear_roots_list_changed).and_return(true)
      allow(server).to receive(:clear_roots_list_changed)
    end

    it "lists all registered root definitions" do
      r1 = double("r1", as_mcp_definition: { "uri" => "file:///path1", "name" => "Project 1" })
      r2 = double("r2", as_mcp_definition: { "uri" => "file:///path2", "name" => "Project 2" })
      roots.merge!("file:///path1" => r1, "file:///path2" => r2)

      result = described_class.list_roots({}, session, server)

      expect(result).to eq({
                             roots: [
                               { "uri" => "file:///path1", "name" => "Project 1" },
                               { "uri" => "file:///path2", "name" => "Project 2" }
                             ]
                           })
    end

    it "returns empty array when no roots are registered" do
      result = described_class.list_roots({}, session, server)

      expect(result).to eq({ roots: [] })
    end

    it "clears the list changed flag after listing" do
      described_class.list_roots({}, session, server)

      expect(server).to have_received(:clear_roots_list_changed)
    end

    it "handles servers that don't support clear_roots_list_changed" do
      allow(server).to receive(:respond_to?).with(:clear_roots_list_changed).and_return(false)

      expect { described_class.list_roots({}, session, server) }.not_to raise_error
      expect(server).not_to have_received(:clear_roots_list_changed)
    end
  end

  describe ".get_prompt" do
    let(:prompt_name) { "greet" }
    let(:handler_proc) do
      proc { { description: "d", messages: [{ role: "user", content: { type: "text", text: "hi" } }] } }
    end
    let(:prompt) { double("prompt", handler: handler_proc, arguments: []) }
    before { server.prompts[prompt_name] = prompt }

    context "when prompt exists and returns valid structure" do
      it "returns the handler result directly" do
        params = { "name" => prompt_name, "arguments" => {} }
        result = described_class.get_prompt(params, session, server)
        expect(result[:description]).to eq("d")
        expect(result[:messages].first[:role]).to eq("user")
      end
    end

    context "when prompt is not registered" do
      before { server.prompts.clear }
      it "raises NotFoundError with proper details" do
        expect do
          described_class.get_prompt({ "name" => "x" }, session, server)
        end.to raise_error(VectorMCP::NotFoundError) { |err|
          expect(err.message).to eq("Not Found")
          expect(err.details).to eq("Prompt not found: x")
        }
      end
    end

    context "when handler returns invalid data structure" do
      let(:handler_proc) { proc { "bad" } }
      let(:prompt) { double("prompt", handler: handler_proc) }
      before { server.prompts[prompt_name] = prompt }

      it "raises InternalError for invalid outer structure" do
        expect do
          described_class.get_prompt({ "name" => prompt_name }, session, server)
        end.to raise_error(VectorMCP::InternalError) { |err|
          expect(err.message).to eq("Prompt handler returned invalid data structure")
        }
      end
    end

    context "when handler returns messages with invalid item structure" do
      let(:handler_proc) do
        proc { { messages: [{ wrong: "x" }] } }
      end
      let(:prompt) { double("prompt", handler: handler_proc) }
      before { server.prompts[prompt_name] = prompt }

      it "raises InternalError for invalid message structure" do
        expect do
          described_class.get_prompt({ "name" => prompt_name }, session, server)
        end.to raise_error(VectorMCP::InternalError) { |err|
          expect(err.message).to eq("Prompt handler returned invalid message structure")
        }
      end
    end

    context "argument validation" do
      let(:prompt_arguments) { [{ name: "req", required: true }, { name: "opt" }] }
      let(:prompt) { double("prompt", handler: ->(_args) { { messages: [] } }, arguments: prompt_arguments) }
      before { server.prompts[prompt_name] = prompt }

      it "raises InvalidParamsError when required args missing" do
        expect do
          described_class.get_prompt({ "name" => prompt_name, "arguments" => {} }, session, server)
        end.to raise_error(VectorMCP::InvalidParamsError) { |err| expect(err.details[:missing]).to include("req") }
      end

      it "raises InvalidParamsError for unknown args" do
        args = { "req" => "v", "extra" => 1 }
        expect do
          described_class.get_prompt({ "name" => prompt_name, "arguments" => args }, session, server)
        end.to raise_error(VectorMCP::InvalidParamsError) { |err| expect(err.details[:unknown]).to include("extra") }
      end
    end
  end

  describe "notification handlers" do
    describe ".initialized_notification" do
      it "logs session initialized" do
        described_class.initialized_notification({}, session, server)
        expect(logger).to have_received(:info).with("Session initialized")
      end
    end

    describe ".cancel_request_notification" do
      it "logs the cancellation request id" do
        described_class.cancel_request_notification({ "id" => "42" }, session, server)
        expect(logger).to have_received(:info).with("Received cancellation request for ID: 42")
      end
    end
  end

  describe ".subscribe_prompts" do
    it "adds session as subscriber without error" do
      server_double = VectorMCP::Server.new(name: "s", version: "1")
      session_double = VectorMCP::Session.new(server_double)
      expect do
        described_class.subscribe_prompts({}, session_double, server_double)
      end.not_to raise_error
    end
  end
end
