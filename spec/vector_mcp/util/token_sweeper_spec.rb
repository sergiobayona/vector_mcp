# frozen_string_literal: true

require "spec_helper"

RSpec.describe VectorMCP::Util::TokenSweeper do
  describe ".sweep" do
    it "raises ArgumentError when invoked without a block" do
      expect { described_class.sweep({}) }.to raise_error(ArgumentError)
    end

    it "yields each String value in a flat Hash with its parent key" do
      received = []
      described_class.sweep({ "a" => "one", "b" => "two" }) do |value, parent_key|
        received << [value, parent_key]
        value
      end
      expect(received).to contain_exactly(%w[one a], %w[two b])
    end

    it "replaces String leaves with the block return value" do
      result = described_class.sweep({ "a" => "one" }) { |value, _| value.upcase }
      expect(result).to eq({ "a" => "ONE" })
    end

    it "recurses into nested Hashes and passes the immediate parent key" do
      input = { "outer" => { "inner" => "value" } }
      received = []
      described_class.sweep(input) do |value, parent_key|
        received << [value, parent_key]
        value
      end
      expect(received).to eq([%w[value inner]])
    end

    it "propagates the Array's own parent key to Array elements" do
      input = { "phones" => %w[555-1 555-2] }
      received = []
      described_class.sweep(input) do |value, parent_key|
        received << [value, parent_key]
        value
      end
      expect(received).to contain_exactly(%w[555-1 phones], %w[555-2 phones])
    end

    it "does not yield for Integer, Float, nil, or Boolean values" do
      yielded = []
      described_class.sweep({ "i" => 1, "f" => 2.5, "n" => nil, "t" => true, "f2" => false }) do |value, _|
        yielded << value
        value
      end
      expect(yielded).to be_empty
    end

    it "returns scalars unchanged at the top level" do
      expect(described_class.sweep(42) { |v, _| v }).to eq(42)
      expect(described_class.sweep(nil) { |v, _| v }).to be_nil
    end

    it "returns a new Hash without mutating the input" do
      input = { "a" => "one" }
      result = described_class.sweep(input) { |v, _| v.upcase }
      expect(input).to eq({ "a" => "one" })
      expect(result).not_to equal(input)
    end

    it "returns a new Array without mutating the input" do
      input = %w[one two]
      result = described_class.sweep({ "xs" => input }) { |v, _| v.upcase }
      expect(input).to eq(%w[one two])
      expect(result["xs"]).not_to equal(input)
    end

    it "handles empty Hash and empty Array" do
      expect(described_class.sweep({}) { |v, _| v }).to eq({})
      expect(described_class.sweep([]) { |v, _| v }).to eq([])
    end

    it "handles top-level String values using nil as parent_key" do
      received_key = nil
      described_class.sweep("top") do |value, parent_key|
        received_key = parent_key
        value
      end
      expect(received_key).to be_nil
    end

    it "is defensive against circular Hash references" do
      cyclic = {}
      cyclic["self"] = cyclic
      expect { described_class.sweep(cyclic) { |v, _| v } }.not_to raise_error
    end

    it "is defensive against circular Array references" do
      cyclic = []
      cyclic << cyclic
      expect { described_class.sweep(cyclic) { |v, _| v } }.not_to raise_error
    end
  end
end
