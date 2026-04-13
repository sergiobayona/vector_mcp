# frozen_string_literal: true

require "spec_helper"
require "vector_mcp/middleware/anonymizer"

RSpec.describe VectorMCP::Middleware::Anonymizer do
  let(:store) { VectorMCP::TokenStore.new }
  let(:field_rules) do
    [
      { pattern: /\balpha\b/i, prefix: "ALPHA" },
      { pattern: /beta/i,      prefix: "BETA"  },
      { pattern: /gamma/i,     prefix: "GAMMA" }
    ]
  end
  let(:atomic_keys) { /\bdelta\b/i }

  subject(:anonymizer) do
    described_class.new(store: store, field_rules: field_rules, atomic_keys: atomic_keys)
  end

  describe "#initialize" do
    it "requires :store" do
      expect { described_class.new(store: nil, field_rules: []) }
        .to raise_error(ArgumentError, /store is required/)
    end

    it "requires :field_rules" do
      expect { described_class.new(store: store, field_rules: nil) }
        .to raise_error(ArgumentError, /field_rules is required/)
    end

    it "rejects rules without :pattern or :prefix" do
      expect do
        described_class.new(store: store, field_rules: [{ pattern: "no-regexp", prefix: "X" }])
      end.to raise_error(ArgumentError, /field_rule/)
    end
  end

  describe "#sweep_outbound" do
    it "replaces string fields whose parent key matches a rule with tokens" do
      result = anonymizer.sweep_outbound({ "alpha" => "one" })
      expect(result["alpha"]).to match(/\AALPHA_[0-9A-F]{8}\z/)
    end

    it "leaves string fields whose parent key does not match any rule unchanged" do
      result = anonymizer.sweep_outbound({ "unknown" => "plain" })
      expect(result).to eq({ "unknown" => "plain" })
    end

    it "recurses into nested structures" do
      input = { "outer" => { "beta" => "secret", "keep" => "as-is" } }
      result = anonymizer.sweep_outbound(input)
      expect(result["outer"]["beta"]).to match(/\ABETA_/)
      expect(result["outer"]["keep"]).to eq("as-is")
    end

    it "propagates the parent key into Arrays" do
      input = { "gamma" => %w[one two] }
      result = anonymizer.sweep_outbound(input)
      expect(result["gamma"]).to all(match(/\AGAMMA_/))
      expect(result["gamma"].uniq.size).to eq(2)
    end

    it "replaces atomic Hash nodes with a single token" do
      input = { "delta" => { "line1" => "123 Somewhere St", "city" => "Somewhere" } }
      result = anonymizer.sweep_outbound(input)
      expect(result["delta"]).to be_a(String)
      expect(result["delta"]).to match(/\A[A-Z]+_[0-9A-F]{8}\z/)
    end

    it "tokenizes identical atomic nodes to the same token" do
      node = { "line1" => "123 Somewhere", "city" => "Somewhere" }
      a = anonymizer.sweep_outbound({ "delta" => node })
      b = anonymizer.sweep_outbound({ "delta" => node })
      expect(a["delta"]).to eq(b["delta"])
    end

    it "produces stable tokens for the same (value, prefix) pair across calls" do
      first = anonymizer.sweep_outbound({ "alpha" => "repeatable" })
      second = anonymizer.sweep_outbound({ "alpha" => "repeatable" })
      expect(first).to eq(second)
    end

    it "does not mutate the input" do
      input = { "alpha" => "one" }
      anonymizer.sweep_outbound(input)
      expect(input).to eq({ "alpha" => "one" })
    end

    it "leaves non-string scalars untouched" do
      result = anonymizer.sweep_outbound({ "alpha" => 42, "count" => 3 })
      expect(result).to eq({ "alpha" => 42, "count" => 3 })
    end
  end

  describe "#sweep_inbound" do
    it "resolves known tokens back to their original values" do
      token = store.tokenize("original", prefix: "ALPHA")
      result = anonymizer.sweep_inbound({ "alpha" => token })
      expect(result["alpha"]).to eq("original")
    end

    it "leaves non-token strings unchanged" do
      result = anonymizer.sweep_inbound({ "alpha" => "plain text" })
      expect(result["alpha"]).to eq("plain text")
    end

    it "leaves unknown token-shaped strings unchanged and does not raise" do
      unknown = "ALPHA_DEADBEEF"
      result = anonymizer.sweep_inbound({ "alpha" => unknown })
      expect(result["alpha"]).to eq(unknown)
    end

    it "resolves tokens nested inside Arrays and Hashes" do
      t1 = store.tokenize("one", prefix: "ALPHA")
      t2 = store.tokenize("two", prefix: "ALPHA")
      input = { "outer" => { "alpha" => t1, "items" => [t1, t2, "plain"] } }
      result = anonymizer.sweep_inbound(input)
      expect(result["outer"]["alpha"]).to eq("one")
      expect(result["outer"]["items"]).to eq(%w[one two plain])
    end
  end

  describe "round-trip" do
    it "returns the original values for all matched field types" do
      original = {
        "alpha" => "value-a",
        "beta" => "value-b",
        "gamma" => %w[g1 g2],
        "unknown" => "as-is"
      }
      outbound = anonymizer.sweep_outbound(original)

      # Simulate the LLM echoing tokens back as tool arguments.
      inbound = anonymizer.sweep_inbound(outbound)

      expect(inbound["alpha"]).to eq("value-a")
      expect(inbound["beta"]).to eq("value-b")
      expect(inbound["gamma"]).to eq(%w[g1 g2])
      expect(inbound["unknown"]).to eq("as-is")
    end

    it "round-trips atomic nodes by resolving the tokenized blob" do
      node = { "line1" => "A", "city" => "B" }
      outbound = anonymizer.sweep_outbound({ "delta" => node })
      resolved = store.resolve(outbound["delta"])
      expect(JSON.parse(resolved)).to eq({ "city" => "B", "line1" => "A" })
    end
  end

  describe "isolation" do
    it "issues different tokens for the same key with different values" do
      a = anonymizer.sweep_outbound({ "alpha" => "customer-1" })
      b = anonymizer.sweep_outbound({ "alpha" => "customer-2" })
      expect(a["alpha"]).not_to eq(b["alpha"])
    end
  end

  describe "middleware hooks" do
    let(:server) { instance_double(VectorMCP::Server, logger: VectorMCP.logger_for("spec")) }
    let(:session) { VectorMCP::Session.new(server, nil, id: "anonymizer-session") }

    def context_with(params: {}, result: nil)
      VectorMCP::Middleware::Context.new(
        operation_type: :tool_call,
        operation_name: "test_tool",
        params: params,
        session: session,
        server: server
      ).tap { |c| c.result = result unless result.nil? }
    end

    describe "#before_tool_call" do
      it "resolves tokens inside context.params[\"arguments\"]" do
        token = store.tokenize("original", prefix: "ALPHA")
        context = context_with(params: { "name" => "tool", "arguments" => { "alpha" => token } })

        anonymizer.before_tool_call(context)
        expect(context.params["arguments"]["alpha"]).to eq("original")
      end

      it "is a no-op when arguments are absent" do
        context = context_with(params: { "name" => "tool" })
        expect { anonymizer.before_tool_call(context) }.not_to raise_error
        expect(context.params["name"]).to eq("tool")
      end
    end

    describe "#after_tool_call" do
      it "tokenizes matched fields in context.result" do
        context = context_with(result: { "alpha" => "secret" })
        anonymizer.after_tool_call(context)
        expect(context.result["alpha"]).to match(/\AALPHA_/)
      end

      it "is a no-op when result is nil" do
        context = context_with
        expect { anonymizer.after_tool_call(context) }.not_to raise_error
      end
    end
  end
end
