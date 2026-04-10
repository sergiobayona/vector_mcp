# frozen_string_literal: true

require "spec_helper"
require "vector_mcp/rails/tool"

RSpec.describe "VectorMCP::Rails::Tool integration with Server", :active_record do
  let(:server) { VectorMCP::Server.new(name: "RailsToolTestServer", version: "1.0.0") }
  let(:session) { VectorMCP::Session.new(server, nil, id: "test-session") }
  let(:widget_model) { VectorMCPRailsToolTestModels::Widget }

  before do
    session.initialize!({
                          "protocolVersion" => "2024-11-05",
                          "clientInfo" => { "name" => "test-client", "version" => "1.0.0" },
                          "capabilities" => {}
                        })
  end

  def invoke(tool_name, arguments = {})
    server.handle_message({
                            "jsonrpc" => "2.0",
                            "id" => 1,
                            "method" => "tools/call",
                            "params" => { "name" => tool_name, "arguments" => arguments }
                          }, session, "test-session")
  end

  describe "find! helper" do
    let(:tool_class) do
      model = widget_model
      Class.new(VectorMCP::Rails::Tool) do
        tool_name "get_widget"
        description "Fetch a widget by ID"
        param :id, type: :integer, required: true

        define_method(:call) do |args, _session|
          widget = find!(model, args[:id])
          { id: widget.id, name: widget.name }
        end
      end
    end

    before { server.register(tool_class) }

    it "returns the record when present" do
      widget = widget_model.create!(name: "Sprocket", quantity: 3)

      result = invoke("get_widget", { "id" => widget.id })

      expect(result[:isError]).to be(false)
      payload = JSON.parse(result[:content][0][:text], symbolize_names: true)
      expect(payload).to eq(id: widget.id, name: "Sprocket")
    end

    it "raises NotFoundError when the record is missing" do
      expect { invoke("get_widget", { "id" => 999_999 }) }
        .to raise_error(VectorMCP::NotFoundError, /Widget 999999 not found/)
    end
  end

  describe "respond_with helper" do
    let(:tool_class) do
      model = widget_model
      Class.new(VectorMCP::Rails::Tool) do
        tool_name "create_widget"
        description "Create a widget"
        param :name, type: :string, required: true
        param :quantity, type: :integer

        define_method(:call) do |args, _session|
          widget = model.create(name: args[:name], quantity: args[:quantity] || 0)
          respond_with(widget, name: widget.name)
        end
      end
    end

    before { server.register(tool_class) }

    it "returns success shape for a valid record" do
      result = invoke("create_widget", { "name" => "Gear", "quantity" => 5 })

      payload = JSON.parse(result[:content][0][:text], symbolize_names: true)
      expect(payload[:success]).to be(true)
      expect(payload[:name]).to eq("Gear")
      expect(widget_model.find(payload[:id]).quantity).to eq(5)
    end

    it "returns error shape for an invalid record" do
      result = invoke("create_widget", { "name" => "", "quantity" => 1 })

      payload = JSON.parse(result[:content][0][:text], symbolize_names: true)
      expect(payload[:success]).to be(false)
      expect(payload[:errors]).to include(/Name can't be blank/)
    end
  end

  describe "indifferent args" do
    let(:tool_class) do
      Class.new(VectorMCP::Rails::Tool) do
        tool_name "indifferent_check"
        description "Verifies args support symbol and string keys"
        param :label, type: :string, required: true

        def call(args, _session)
          { from_symbol: args[:label], from_string: args["label"] }
        end
      end
    end

    before { server.register(tool_class) }

    it "allows accessing args with either symbol or string keys" do
      result = invoke("indifferent_check", { "label" => "hello" })

      payload = JSON.parse(result[:content][0][:text], symbolize_names: true)
      expect(payload[:from_symbol]).to eq("hello")
      expect(payload[:from_string]).to eq("hello")
    end
  end
end
