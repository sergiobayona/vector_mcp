# frozen_string_literal: true

require "spec_helper"

RSpec.describe VectorMCP::Tool do
  describe "class-level DSL" do
    describe ".tool_name" do
      it "stores and returns an explicitly set name" do
        klass = Class.new(described_class) do
          tool_name "explicit_name"
          description "A tool"
          def call(_args, _session); end
        end

        expect(klass.tool_name).to eq("explicit_name")
      end

      it "derives a snake_case name from the class name when not set" do
        stub_const("ListProviders", Class.new(described_class) do
          description "A tool"
          def call(_args, _session); end
        end)

        expect(ListProviders.tool_name).to eq("list_providers")
      end

      it "derives name from nested class name using only the last segment" do
        stub_const("MyModule::FetchUserData", Class.new(described_class) do
          description "A tool"
          def call(_args, _session); end
        end)

        expect(MyModule::FetchUserData.tool_name).to eq("fetch_user_data")
      end

      it "returns 'unnamed_tool' for anonymous classes" do
        klass = Class.new(described_class) do
          description "A tool"
          def call(_args, _session); end
        end

        expect(klass.tool_name).to eq("unnamed_tool")
      end

      it "converts symbol names to strings" do
        klass = Class.new(described_class) do
          tool_name :my_tool
          description "A tool"
          def call(_args, _session); end
        end

        expect(klass.tool_name).to eq("my_tool")
      end
    end

    describe ".description" do
      it "stores and returns the description" do
        klass = Class.new(described_class) do
          description "Does something useful"
          def call(_args, _session); end
        end

        expect(klass.description).to eq("Does something useful")
      end

      it "returns nil when not set" do
        klass = Class.new(described_class) do
          def call(_args, _session); end
        end

        expect(klass.description).to be_nil
      end
    end

    describe ".param" do
      it "builds correct JSON Schema properties" do
        klass = Class.new(described_class) do
          tool_name "test_tool"
          description "A test tool"
          param :category, type: :string, desc: "Filter by category"
          param :count, type: :integer, desc: "Number of results"
          def call(_args, _session); end
        end

        definition = klass.to_definition
        schema = definition.input_schema

        expect(schema["type"]).to eq("object")
        expect(schema["properties"]["category"]).to eq(
          "type" => "string",
          "description" => "Filter by category"
        )
        expect(schema["properties"]["count"]).to eq(
          "type" => "integer",
          "description" => "Number of results"
        )
      end

      it "populates the required array for required params" do
        klass = Class.new(described_class) do
          tool_name "test_tool"
          description "A test tool"
          param :name, type: :string, required: true
          param :age, type: :integer
          def call(_args, _session); end
        end

        definition = klass.to_definition
        schema = definition.input_schema

        expect(schema["required"]).to eq(["name"])
      end

      it "omits the required key when no params are required" do
        klass = Class.new(described_class) do
          tool_name "test_tool"
          description "A test tool"
          param :name, type: :string
          def call(_args, _session); end
        end

        definition = klass.to_definition
        schema = definition.input_schema

        expect(schema).not_to have_key("required")
      end

      it "supports all JSON Schema types" do
        klass = Class.new(described_class) do
          tool_name "type_test"
          description "Tests all types"
          param :s, type: :string
          param :i, type: :integer
          param :n, type: :number
          param :b, type: :boolean
          param :a, type: :array
          param :o, type: :object
          def call(_args, _session); end
        end

        schema = klass.to_definition.input_schema
        expect(schema["properties"]["s"]["type"]).to eq("string")
        expect(schema["properties"]["i"]["type"]).to eq("integer")
        expect(schema["properties"]["n"]["type"]).to eq("number")
        expect(schema["properties"]["b"]["type"]).to eq("boolean")
        expect(schema["properties"]["a"]["type"]).to eq("array")
        expect(schema["properties"]["o"]["type"]).to eq("object")
      end

      it "passes additional JSON Schema options through" do
        klass = Class.new(described_class) do
          tool_name "enum_tool"
          description "Tool with enum"
          param :role, type: :string, desc: "User role", enum: %w[admin user guest]
          param :score, type: :number, default: 0.0, minimum: 0, maximum: 100
          param :tags, type: :array, items: { "type" => "string" }
          param :email, type: :string, format: "email"
          def call(_args, _session); end
        end

        schema = klass.to_definition.input_schema
        expect(schema["properties"]["role"]["enum"]).to eq(%w[admin user guest])
        expect(schema["properties"]["score"]["default"]).to eq(0.0)
        expect(schema["properties"]["score"]["minimum"]).to eq(0)
        expect(schema["properties"]["score"]["maximum"]).to eq(100)
        expect(schema["properties"]["tags"]["items"]).to eq({ "type" => "string" })
        expect(schema["properties"]["email"]["format"]).to eq("email")
      end

      it "raises ArgumentError for unknown type" do
        klass = Class.new(described_class) do
          tool_name "bad_type"
          description "Bad type tool"
          param :x, type: :datetime
          def call(_args, _session); end
        end

        expect { klass.to_definition }.to raise_error(ArgumentError, /Unknown param type :datetime/)
      end
    end
  end

  describe ".to_definition" do
    it "returns a VectorMCP::Definitions::Tool struct" do
      klass = Class.new(described_class) do
        tool_name "my_tool"
        description "My tool"
        param :input, type: :string, desc: "The input"
        def call(args, _session)
          args["input"].upcase
        end
      end

      definition = klass.to_definition

      expect(definition).to be_a(VectorMCP::Definitions::Tool)
      expect(definition.name).to eq("my_tool")
      expect(definition.description).to eq("My tool")
      expect(definition.input_schema).to be_a(Hash)
      expect(definition.handler).to respond_to(:call)
    end

    it "produces a handler with arity 2" do
      klass = Class.new(described_class) do
        tool_name "arity_test"
        description "Arity test"
        def call(_args, _session); end
      end

      definition = klass.to_definition
      expect(definition.handler.arity).to eq(2)
    end

    it "handler invokes #call on a new instance each time" do
      call_count = 0
      klass = Class.new(described_class) do
        tool_name "instance_test"
        description "Instance test"
        define_method(:call) do |_args, _session|
          call_count += 1
          "result_#{call_count}"
        end
      end

      definition = klass.to_definition
      result1 = definition.handler.call({}, nil)
      result2 = definition.handler.call({}, nil)

      expect(result1).to eq("result_1")
      expect(result2).to eq("result_2")
      expect(call_count).to eq(2)
    end

    it "handler passes args and session to #call" do
      received = {}
      klass = Class.new(described_class) do
        tool_name "pass_through"
        description "Pass through"
        define_method(:call) do |args, session|
          received[:args] = args
          received[:session] = session
          "ok"
        end
      end

      definition = klass.to_definition
      mock_session = double("session")
      definition.handler.call({ "foo" => "bar" }, mock_session)

      expect(received[:args]).to eq({ "foo" => "bar" })
      expect(received[:session]).to be(mock_session)
    end

    it "raises ArgumentError when description is missing" do
      klass = Class.new(described_class) do
        tool_name "no_desc"
        def call(_args, _session); end
      end

      expect { klass.to_definition }.to raise_error(ArgumentError, /must declare a description/)
    end

    it "raises ArgumentError when #call is not implemented" do
      klass = Class.new(described_class) do
        tool_name "no_call"
        description "Missing call"
      end

      expect { klass.to_definition }.to raise_error(ArgumentError, /must implement #call/)
    end

    it "builds an empty-properties schema when no params are declared" do
      klass = Class.new(described_class) do
        tool_name "no_params"
        description "No params"
        def call(_args, _session)
          "ok"
        end
      end

      definition = klass.to_definition
      expect(definition.input_schema).to eq(
        "type" => "object",
        "properties" => {}
      )
    end

    it "produces a valid MCP definition via as_mcp_definition" do
      klass = Class.new(described_class) do
        tool_name "mcp_test"
        description "MCP test"
        param :query, type: :string, desc: "Search query", required: true
        def call(_args, _session); end
      end

      definition = klass.to_definition
      mcp_def = definition.as_mcp_definition

      expect(mcp_def[:name]).to eq("mcp_test")
      expect(mcp_def[:description]).to eq("MCP test")
      expect(mcp_def[:inputSchema]["type"]).to eq("object")
      expect(mcp_def[:inputSchema]["properties"]["query"]["type"]).to eq("string")
    end
  end

  describe "subclass isolation" do
    it "does not share params between sibling subclasses" do
      klass_a = Class.new(described_class) do
        tool_name "tool_a"
        description "Tool A"
        param :a_param, type: :string
        def call(_args, _session); end
      end

      klass_b = Class.new(described_class) do
        tool_name "tool_b"
        description "Tool B"
        param :b_param, type: :integer
        def call(_args, _session); end
      end

      schema_a = klass_a.to_definition.input_schema
      schema_b = klass_b.to_definition.input_schema

      expect(schema_a["properties"]).to have_key("a_param")
      expect(schema_a["properties"]).not_to have_key("b_param")
      expect(schema_b["properties"]).to have_key("b_param")
      expect(schema_b["properties"]).not_to have_key("a_param")
    end

    it "does not share tool_name between sibling subclasses" do
      klass_a = Class.new(described_class) do
        tool_name "alpha"
        description "Alpha"
        def call(_args, _session); end
      end

      klass_b = Class.new(described_class) do
        tool_name "beta"
        description "Beta"
        def call(_args, _session); end
      end

      expect(klass_a.tool_name).to eq("alpha")
      expect(klass_b.tool_name).to eq("beta")
    end
  end
end
