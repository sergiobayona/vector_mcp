# frozen_string_literal: true

require "spec_helper"
require "vector_mcp/rails/tool"

RSpec.describe VectorMCP::Rails::Tool, :active_record do
  let(:widget_model) { VectorMCPRailsToolTestModels::Widget }

  describe "#find!" do
    it "returns the record when present" do
      widget = widget_model.create!(name: "Bolt", quantity: 1)
      tool = Class.new(described_class) do
        tool_name "x"
        description "x"
        def call(_args, _session); end
      end.new

      expect(tool.find!(widget_model, widget.id)).to eq(widget)
    end

    it "raises VectorMCP::NotFoundError when the record is missing" do
      tool = Class.new(described_class) do
        tool_name "x"
        description "x"
        def call(_args, _session); end
      end.new

      expect { tool.find!(widget_model, 424_242) }
        .to raise_error(
          VectorMCP::NotFoundError,
          /VectorMCPRailsToolTestModels::Widget 424242 not found/
        )
    end
  end

  describe "#respond_with" do
    let(:tool_instance) do
      Class.new(described_class) do
        tool_name "x"
        description "x"
        def call(_args, _session); end
      end.new
    end

    it "returns a success payload for a valid persisted record" do
      widget = widget_model.create!(name: "Nut", quantity: 2)

      result = tool_instance.respond_with(widget, name: widget.name)

      expect(result).to eq(success: true, id: widget.id, name: "Nut")
    end

    it "includes extras in the success payload" do
      widget = widget_model.create!(name: "Washer")

      result = tool_instance.respond_with(widget, foo: "bar", quantity: widget.quantity)

      expect(result[:success]).to be(true)
      expect(result[:foo]).to eq("bar")
      expect(result[:quantity]).to eq(0)
    end

    it "returns an error payload when the record is invalid" do
      widget = widget_model.new(name: "") # invalid
      widget.valid? # populate errors

      result = tool_instance.respond_with(widget)

      expect(result[:success]).to be(false)
      expect(result[:errors]).to include(/Name can't be blank/)
    end

    it "returns an error payload when save failed (record not persisted)" do
      widget = widget_model.new(name: "", quantity: -5)
      widget.save

      result = tool_instance.respond_with(widget)

      expect(result[:success]).to be(false)
      expect(result[:errors]).not_to be_empty
    end
  end

  describe "#with_transaction" do
    let(:tool_instance) do
      Class.new(described_class) do
        tool_name "x"
        description "x"
        def call(_args, _session); end
      end.new
    end

    it "commits when the block returns normally" do
      tool_instance.with_transaction do
        widget_model.create!(name: "Pin")
      end

      expect(widget_model.where(name: "Pin").count).to eq(1)
    end

    it "rolls back when the block raises" do
      expect do
        tool_instance.with_transaction do
          widget_model.create!(name: "Cotter")
          raise "boom"
        end
      end.to raise_error("boom")

      expect(widget_model.where(name: "Cotter").count).to eq(0)
    end
  end

  describe "auto-rescue of ActiveRecord exceptions" do
    it "converts ActiveRecord::RecordNotFound raised inside #call to VectorMCP::NotFoundError" do
      model = widget_model
      klass = Class.new(described_class) do
        tool_name "raiser"
        description "raises AR::RecordNotFound"
        define_method(:call) do |_args, _session|
          model.find(999_999)
        end
      end

      handler = klass.to_definition.handler

      expect { handler.call({}, nil) }.to raise_error(VectorMCP::NotFoundError)
    end

    it "converts ActiveRecord::RecordInvalid raised inside #call to an error payload" do
      model = widget_model
      klass = Class.new(described_class) do
        tool_name "invalid_raiser"
        description "raises AR::RecordInvalid"
        define_method(:call) do |_args, _session|
          model.create!(name: "") # RecordInvalid
        end
      end

      handler = klass.to_definition.handler
      result = handler.call({}, nil)

      expect(result[:success]).to be(false)
      expect(result[:errors]).to include(/Name can't be blank/)
    end

    it "lets unrelated exceptions bubble up unchanged" do
      klass = Class.new(described_class) do
        tool_name "other_raiser"
        description "raises something unrelated"
        def call(_args, _session)
          raise ArgumentError, "something else"
        end
      end

      handler = klass.to_definition.handler

      expect { handler.call({}, nil) }.to raise_error(ArgumentError, "something else")
    end
  end

  describe "indifferent args" do
    it "allows accessing args with both string and symbol keys inside #call" do
      received = {}
      klass = Class.new(described_class) do
        tool_name "indifferent"
        description "indifferent args"
        param :name, type: :string
        define_method(:call) do |args, _session|
          received[:by_sym] = args[:name]
          received[:by_str] = args["name"]
        end
      end

      klass.to_definition.handler.call({ "name" => "hello" }, nil)

      expect(received[:by_sym]).to eq("hello")
      expect(received[:by_str]).to eq("hello")
    end

    it "still coerces :date params (Phase 1 behavior preserved)" do
      received = nil
      klass = Class.new(described_class) do
        tool_name "date_in_rails"
        description "date coercion under Rails::Tool"
        param :when, type: :date
        define_method(:call) do |args, _session|
          received = args[:when]
        end
      end

      klass.to_definition.handler.call({ "when" => "2026-12-31" }, nil)

      expect(received).to be_a(Date)
      expect(received).to eq(Date.new(2026, 12, 31))
    end
  end
end
