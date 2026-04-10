# frozen_string_literal: true

require "spec_helper"

RSpec.describe "VectorMCP::Tool integration with Server" do
  let(:server) { VectorMCP::Server.new(name: "ToolDSLTestServer", version: "1.0.0") }
  let(:session) { VectorMCP::Session.new(server, nil, id: "test-session") }

  before do
    session.initialize!({
                          "protocolVersion" => "2024-11-05",
                          "clientInfo" => { "name" => "test-client", "version" => "1.0.0" },
                          "capabilities" => {}
                        })
  end

  describe "server.register" do
    it "registers a single tool class" do
      tool_class = Class.new(VectorMCP::Tool) do
        tool_name "echo"
        description "Echoes input"
        param :message, type: :string, desc: "Message to echo", required: true

        def call(args, _session)
          args["message"]
        end
      end

      server.register(tool_class)

      expect(server.tools).to have_key("echo")
      expect(server.tools["echo"]).to be_a(VectorMCP::Definitions::Tool)
      expect(server.tools["echo"].description).to eq("Echoes input")
    end

    it "registers multiple tool classes at once" do
      tool_a = Class.new(VectorMCP::Tool) do
        tool_name "tool_a"
        description "Tool A"
        def call(_args, _session); end
      end

      tool_b = Class.new(VectorMCP::Tool) do
        tool_name "tool_b"
        description "Tool B"
        def call(_args, _session); end
      end

      server.register(tool_a, tool_b)

      expect(server.tools).to have_key("tool_a")
      expect(server.tools).to have_key("tool_b")
    end

    it "returns self for method chaining" do
      tool_class = Class.new(VectorMCP::Tool) do
        tool_name "chainable"
        description "Chainable"
        def call(_args, _session); end
      end

      result = server.register(tool_class)
      expect(result).to be(server)
    end

    it "raises ArgumentError for non-Tool classes" do
      expect { server.register(String) }.to raise_error(ArgumentError, /is not a VectorMCP::Tool subclass/)
    end

    it "raises ArgumentError for plain objects" do
      expect { server.register("not_a_class") }.to raise_error(ArgumentError, /is not a VectorMCP::Tool subclass/)
    end

    it "raises ArgumentError for duplicate tool names" do
      tool_class = Class.new(VectorMCP::Tool) do
        tool_name "duplicate"
        description "Duplicate"
        def call(_args, _session); end
      end

      server.register(tool_class)
      expect { server.register(tool_class) }.to raise_error(ArgumentError, /already registered/)
    end

    it "coexists with block-based register_tool" do
      server.register_tool(
        name: "block_tool",
        description: "Block-based tool",
        input_schema: { "type" => "object", "properties" => {} }
      ) { |_args| "block result" }

      class_tool = Class.new(VectorMCP::Tool) do
        tool_name "class_tool"
        description "Class-based tool"
        def call(_args, _session)
          "class result"
        end
      end

      server.register(class_tool)

      expect(server.tools).to have_key("block_tool")
      expect(server.tools).to have_key("class_tool")
    end
  end

  describe "tool invocation via handle_message" do
    it "executes the class-based tool handler and returns the result" do
      tool_class = Class.new(VectorMCP::Tool) do
        tool_name "greet"
        description "Generates a greeting"
        param :name, type: :string, desc: "Name to greet", required: true

        def call(args, _session)
          "Hello, #{args["name"]}!"
        end
      end

      server.register(tool_class)

      result = server.handle_message({
                                       "jsonrpc" => "2.0",
                                       "id" => 1,
                                       "method" => "tools/call",
                                       "params" => {
                                         "name" => "greet",
                                         "arguments" => { "name" => "World" }
                                       }
                                     }, session, "test-session")

      expect(result[:isError]).to be(false)
      expect(result[:content][0][:text]).to eq("Hello, World!")
    end

    it "passes session to the handler" do
      tool_class = Class.new(VectorMCP::Tool) do
        tool_name "session_checker"
        description "Checks session"

        def call(_args, session)
          session.id
        end
      end

      server.register(tool_class)

      result = server.handle_message({
                                       "jsonrpc" => "2.0",
                                       "id" => 1,
                                       "method" => "tools/call",
                                       "params" => {
                                         "name" => "session_checker",
                                         "arguments" => {}
                                       }
                                     }, session, "test-session")

      expect(result[:isError]).to be(false)
      expect(result[:content][0][:text]).to eq(session.id)
    end

    it "validates input against the generated JSON Schema" do
      tool_class = Class.new(VectorMCP::Tool) do
        tool_name "validated_tool"
        description "Validated tool"
        param :count, type: :integer, desc: "A count", required: true

        def call(args, _session)
          args["count"] * 2
        end
      end

      server.register(tool_class)

      expect do
        server.handle_message({
                                "jsonrpc" => "2.0",
                                "id" => 1,
                                "method" => "tools/call",
                                "params" => {
                                  "name" => "validated_tool",
                                  "arguments" => { "count" => "not_a_number" }
                                }
                              }, session, "test-session")
      end.to raise_error(VectorMCP::InvalidParamsError)
    end

    it "validates required params" do
      tool_class = Class.new(VectorMCP::Tool) do
        tool_name "required_tool"
        description "Required tool"
        param :name, type: :string, required: true

        def call(args, _session)
          args["name"]
        end
      end

      server.register(tool_class)

      expect do
        server.handle_message({
                                "jsonrpc" => "2.0",
                                "id" => 1,
                                "method" => "tools/call",
                                "params" => {
                                  "name" => "required_tool",
                                  "arguments" => {}
                                }
                              }, session, "test-session")
      end.to raise_error(VectorMCP::InvalidParamsError)
    end
  end

  describe "date-aware param types" do
    it "coerces :date param strings to Date objects before handler runs" do
      received = {}
      tool_class = Class.new(VectorMCP::Tool) do
        tool_name "date_coercer"
        description "Receives a date"
        param :when, type: :date, desc: "The date", required: true

        define_method(:call) do |args, _session|
          received[:value] = args["when"]
          received[:class] = args["when"].class
          "ok"
        end
      end

      server.register(tool_class)

      result = server.handle_message({
                                       "jsonrpc" => "2.0",
                                       "id" => 1,
                                       "method" => "tools/call",
                                       "params" => {
                                         "name" => "date_coercer",
                                         "arguments" => { "when" => "2026-12-31" }
                                       }
                                     }, session, "test-session")

      expect(result[:isError]).to be(false)
      expect(received[:class]).to eq(Date)
      expect(received[:value]).to eq(Date.new(2026, 12, 31))
    end

    it "returns an InvalidParamsError (-32602) when a :date arg is unparseable" do
      tool_class = Class.new(VectorMCP::Tool) do
        tool_name "date_bad_e2e"
        description "Takes a date"
        param :when, type: :date, required: true
        def call(_args, _session)
          "ok"
        end
      end

      server.register(tool_class)

      expect do
        server.handle_message({
                                "jsonrpc" => "2.0",
                                "id" => 1,
                                "method" => "tools/call",
                                "params" => {
                                  "name" => "date_bad_e2e",
                                  "arguments" => { "when" => "garbage" }
                                }
                              }, session, "test-session")
      end.to raise_error(VectorMCP::InvalidParamsError) do |error|
        expect(error.code).to eq(-32_602)
      end
    end

    it "returns an InvalidParamsError (-32602) when a :datetime arg is unparseable" do
      tool_class = Class.new(VectorMCP::Tool) do
        tool_name "datetime_bad_e2e"
        description "Takes a datetime"
        param :at, type: :datetime, required: true
        def call(_args, _session)
          "ok"
        end
      end

      server.register(tool_class)

      expect do
        server.handle_message({
                                "jsonrpc" => "2.0",
                                "id" => 1,
                                "method" => "tools/call",
                                "params" => {
                                  "name" => "datetime_bad_e2e",
                                  "arguments" => { "at" => "garbage" }
                                }
                              }, session, "test-session")
      end.to raise_error(VectorMCP::InvalidParamsError) do |error|
        expect(error.code).to eq(-32_602)
      end
    end

    it "advertises :date params with format: date in the JSON Schema" do
      tool_class = Class.new(VectorMCP::Tool) do
        tool_name "date_schema"
        description "Date schema tool"
        param :valid_until, type: :date, desc: "Expiration"
        def call(_args, _session); end
      end

      server.register(tool_class)

      result = server.handle_message({
                                       "jsonrpc" => "2.0",
                                       "id" => 1,
                                       "method" => "tools/list",
                                       "params" => {}
                                     }, session, "test-session")

      tool_def = result[:tools].find { |t| t[:name] == "date_schema" }
      prop = tool_def[:inputSchema]["properties"]["valid_until"]
      expect(prop["type"]).to eq("string")
      expect(prop["format"]).to eq("date")
    end
  end

  describe "tools/list includes class-based tools" do
    it "lists class-based tools in the tool definitions" do
      tool_class = Class.new(VectorMCP::Tool) do
        tool_name "listed_tool"
        description "A listed tool"
        param :query, type: :string, desc: "Search query"
        def call(_args, _session); end
      end

      server.register(tool_class)

      result = server.handle_message({
                                       "jsonrpc" => "2.0",
                                       "id" => 1,
                                       "method" => "tools/list",
                                       "params" => {}
                                     }, session, "test-session")

      tool_def = result[:tools].find { |t| t[:name] == "listed_tool" }
      expect(tool_def).not_to be_nil
      expect(tool_def[:description]).to eq("A listed tool")
      expect(tool_def[:inputSchema]["type"]).to eq("object")
      expect(tool_def[:inputSchema]["properties"]["query"]["type"]).to eq("string")
    end
  end
end
