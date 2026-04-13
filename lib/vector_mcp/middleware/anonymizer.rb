# frozen_string_literal: true

require "json"

require_relative "base"
require_relative "../token_store"
require_relative "../util/token_sweeper"

module VectorMCP
  module Middleware
    # Middleware that rewrites selected string fields in outbound tool
    # results into opaque tokens and restores them on inbound tool
    # invocations. All domain knowledge (which keys to match, token
    # prefixes, which keys to treat as atomic blobs) is supplied by the
    # application via the constructor.
    #
    # @example Wiring on a server
    #   anonymizer = VectorMCP::Middleware::Anonymizer.new(
    #     store:       VectorMCP::TokenStore.new,
    #     field_rules: [
    #       { pattern: /\bname\b/i, prefix: "NAME"  },
    #       { pattern: /email/i,    prefix: "EMAIL" }
    #     ],
    #     atomic_keys: /address/i
    #   )
    #   anonymizer.install_on(server)
    class Anonymizer
      # @param store [VectorMCP::TokenStore] the backing token store.
      # @param field_rules [Array<Hash>] an array of +{ pattern: Regexp, prefix: String }+
      #   hashes. The pattern is matched against each Hash key whose value is a String.
      # @param atomic_keys [Regexp, nil] optional pattern; Hash values whose parent
      #   key matches are serialized and tokenized as a single opaque unit instead
      #   of recursed into.
      def initialize(store:, field_rules:, atomic_keys: nil)
        raise ArgumentError, "store is required"       if store.nil?
        raise ArgumentError, "field_rules is required" if field_rules.nil?

        @store = store
        @field_rules = field_rules.map { |rule| validate_rule!(rule) }.freeze
        @atomic_keys = atomic_keys
      end

      # Tokenize sensitive string fields in an outbound payload.
      #
      # @param obj [Object] a parsed JSON-like Ruby structure.
      # @return [Object] a new structure with matched values replaced by tokens.
      def sweep_outbound(obj)
        replace_atomic_nodes(obj).then do |shaped|
          VectorMCP::Util::TokenSweeper.sweep(shaped) do |value, parent_key|
            rule = rule_for(parent_key)
            rule ? @store.tokenize(value, prefix: rule[:prefix]) : value
          end
        end
      end

      # Resolve tokens in an inbound payload back to their original values.
      # Unknown token-shaped strings pass through unchanged.
      #
      # @param obj [Object] a parsed JSON-like Ruby structure.
      # @return [Object] a new structure with tokens resolved to original values.
      def sweep_inbound(obj)
        VectorMCP::Util::TokenSweeper.sweep(obj) do |value, _parent_key|
          if @store.token?(value)
            resolved = @store.resolve(value)
            resolved.nil? ? value : resolved
          else
            value
          end
        end
      end

      # Middleware hook: rewrite tool arguments before the handler runs.
      # @param context [VectorMCP::Middleware::Context]
      def before_tool_call(context)
        return unless context.params.is_a?(Hash)

        arguments = context.params["arguments"]
        return unless arguments.is_a?(Hash) || arguments.is_a?(Array)

        context.params = context.params.merge("arguments" => sweep_inbound(arguments))
      end

      # Middleware hook: tokenize matched fields in the tool result.
      # @param context [VectorMCP::Middleware::Context]
      def after_tool_call(context)
        return if context.result.nil?

        context.result = sweep_outbound(context.result)
      end

      # Register this anonymizer instance on +server+ for the tool call
      # lifecycle. Creates a thin adapter class so the middleware manager's
      # argumentless instantiation can still deliver the configured instance.
      #
      # @param server [VectorMCP::Server] the server instance.
      # @param priority [Integer] middleware priority.
      # @return [Class] the adapter class registered with the server.
      def install_on(server, priority: Hook::DEFAULT_PRIORITY)
        instance = self
        adapter = Class.new(Base) do
          define_method(:before_tool_call) { |context| instance.before_tool_call(context) }
          define_method(:after_tool_call)  { |context| instance.after_tool_call(context) }
        end
        server.use_middleware(adapter, %i[before_tool_call after_tool_call], priority: priority)
        adapter
      end

      private

      def validate_rule!(rule)
        unless rule.is_a?(Hash) && rule[:pattern].is_a?(Regexp) && rule[:prefix].is_a?(String)
          raise ArgumentError,
                "each field_rule must be a Hash with :pattern (Regexp) and :prefix (String)"
        end

        rule
      end

      def rule_for(parent_key)
        return nil if parent_key.nil?

        key_string = parent_key.to_s
        @field_rules.find { |rule| rule[:pattern].match?(key_string) }
      end

      def atomic_match?(parent_key)
        return false if @atomic_keys.nil? || parent_key.nil?

        @atomic_keys.match?(parent_key.to_s)
      end

      # First pass: collapse Hash nodes whose parent key matches +atomic_keys+
      # into a single tokenized string. A fresh traversal avoids entanglement
      # with the field-rule sweep that runs afterwards.
      def replace_atomic_nodes(obj, parent_key = nil, visited = {}.compare_by_identity)
        case obj
        when Hash
          return obj if visited[obj]

          if atomic_match?(parent_key)
            @store.tokenize(canonical_json(obj), prefix: atomic_prefix_for(parent_key))
          else
            visited[obj] = true
            begin
              obj.each_with_object({}) do |(key, value), out|
                out[key] = replace_atomic_nodes(value, key, visited)
              end
            ensure
              visited.delete(obj)
            end
          end
        when Array
          return obj if visited[obj]

          visited[obj] = true
          begin
            obj.map { |element| replace_atomic_nodes(element, parent_key, visited) }
          ensure
            visited.delete(obj)
          end
        else
          obj
        end
      end

      # Atomic nodes use the prefix of the first field rule whose pattern
      # matches the enclosing key. If no field rule matches, fall back to a
      # neutral default so the token is still well-formed.
      def atomic_prefix_for(parent_key)
        rule_for(parent_key)&.dig(:prefix) || "ATOM"
      end

      def canonical_json(hash)
        JSON.generate(canonicalize(hash))
      end

      def canonicalize(obj)
        case obj
        when Hash  then obj.keys.map(&:to_s).sort.to_h { |k| [k, canonicalize(obj[k] || obj[k.to_sym])] }
        when Array then obj.map { |element| canonicalize(element) }
        else obj
        end
      end
    end
  end
end
