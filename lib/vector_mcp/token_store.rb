# frozen_string_literal: true

require "concurrent-ruby"
require "securerandom"

module VectorMCP
  # Thread-safe bidirectional store mapping arbitrary string values to opaque
  # tokens and back. The store has no knowledge of domain semantics: callers
  # supply the prefix, and the store guarantees that the same (value, prefix)
  # pair always yields the same token within its lifetime.
  class TokenStore
    # Regexp describing the token format emitted by {#tokenize}.
    TOKEN_PATTERN = /\A[A-Z]+_[0-9A-F]{8}\z/

    def initialize
      @forward = Concurrent::Hash.new
      @reverse = Concurrent::Hash.new
      @mutex = Mutex.new
    end

    # Return an opaque token for +value+. Calling this repeatedly with the
    # same +value+ and +prefix+ returns the same token.
    #
    # @param value [String] the value to tokenize.
    # @param prefix [String] the token prefix (uppercase recommended).
    # @return [String] a token of the form +"PREFIX_XXXXXXXX"+.
    def tokenize(value, prefix:)
      key = [prefix, value]
      existing = @forward[key]
      return existing if existing

      @mutex.synchronize do
        existing = @forward[key]
        return existing if existing

        token = generate_token(prefix)
        # Populate the reverse map first so any thread that observes the
        # token in @forward can always resolve it.
        @reverse[token] = value
        @forward[key] = token
        token
      end
    end

    # Resolve a token back to its original value.
    #
    # @param token [String] a token previously returned by {#tokenize}.
    # @return [String, nil] the original value, or +nil+ if unknown.
    def resolve(token)
      @reverse[token]
    end

    # Predicate: does +string+ look like a token issued by this class?
    # This check is purely structural and does not consult the store.
    #
    # @param string [Object] the value to test.
    # @return [Boolean]
    def token?(string)
      string.is_a?(String) && TOKEN_PATTERN.match?(string)
    end

    # Remove all mappings. Intended for test teardown.
    # @return [void]
    def clear
      @mutex.synchronize do
        @forward.clear
        @reverse.clear
      end
    end

    private

    def generate_token(prefix)
      loop do
        candidate = "#{prefix}_#{SecureRandom.hex(4).upcase}"
        return candidate unless @reverse.key?(candidate)
      end
    end
  end
end
