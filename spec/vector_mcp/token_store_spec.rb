# frozen_string_literal: true

require "spec_helper"

RSpec.describe VectorMCP::TokenStore do
  subject(:store) { described_class.new }

  describe "#tokenize" do
    it "returns a string matching the token pattern" do
      token = store.tokenize("alpha", prefix: "NAME")
      expect(token).to match(described_class::TOKEN_PATTERN)
      expect(token).to start_with("NAME_")
    end

    it "is idempotent for the same value and prefix" do
      first = store.tokenize("alpha", prefix: "NAME")
      second = store.tokenize("alpha", prefix: "NAME")
      expect(second).to eq(first)
    end

    it "produces different tokens for different values" do
      a = store.tokenize("alpha", prefix: "X")
      b = store.tokenize("beta",  prefix: "X")
      expect(a).not_to eq(b)
    end

    it "produces different tokens for the same value under different prefixes" do
      a = store.tokenize("alpha", prefix: "ONE")
      b = store.tokenize("alpha", prefix: "TWO")
      expect(a).not_to eq(b)
    end
  end

  describe "#resolve" do
    it "returns the original value for a known token" do
      token = store.tokenize("alpha", prefix: "NAME")
      expect(store.resolve(token)).to eq("alpha")
    end

    it "returns nil for an unknown token" do
      expect(store.resolve("NAME_DEADBEEF")).to be_nil
    end

    it "returns nil for a non-token string" do
      expect(store.resolve("alpha")).to be_nil
    end
  end

  describe "#token?" do
    it "returns true for a token emitted by this class" do
      token = store.tokenize("alpha", prefix: "NAME")
      expect(store.token?(token)).to be true
    end

    it "returns true for any string matching the token pattern, without consulting the store" do
      expect(store.token?("NAME_12345678")).to be true
    end

    it "returns false for a plain string" do
      expect(store.token?("alpha")).to be false
    end

    it "returns false for non-string input" do
      expect(store.token?(nil)).to be false
      expect(store.token?(42)).to be false
    end
  end

  describe "#clear" do
    it "removes all mappings" do
      token = store.tokenize("alpha", prefix: "NAME")
      store.clear
      expect(store.resolve(token)).to be_nil
      expect(store.tokenize("alpha", prefix: "NAME")).not_to eq(token)
    end
  end

  describe "thread safety" do
    it "returns a single token for 100 concurrent tokenize calls on the same value" do
      threads = Array.new(100) do
        Thread.new { store.tokenize("shared", prefix: "N") }
      end
      tokens = threads.map(&:value)
      expect(tokens.uniq.size).to eq(1)
    end

    it "guarantees a token returned from tokenize is immediately resolvable" do
      # If @reverse is populated after @forward, a thread that observes the
      # token in @forward (e.g., via a concurrent tokenize) could resolve it
      # to nil. This test pins the consistency invariant.
      results = Concurrent::Array.new
      writers = Array.new(50) { Thread.new { results << store.tokenize("v", prefix: "P") } }
      readers = Array.new(50) do
        Thread.new do
          token = store.tokenize("v", prefix: "P")
          results << store.resolve(token)
        end
      end
      (writers + readers).each(&:join)
      expect(results.compact.uniq).to contain_exactly(a_string_matching(/\AP_/), "v")
    end
  end
end
