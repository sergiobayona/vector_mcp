# frozen_string_literal: true

module VectorMCP
  # Filters sensitive data from values before they are written to logs.
  # Redacts known sensitive keys in hashes and token patterns in strings.
  module LogFilter
    SENSITIVE_KEYS = %w[
      authorization x-api-key api_key apikey token jwt_token
      password secret cookie set-cookie x-jwt-token
    ].freeze

    FILTERED = "[FILTERED]"

    # Bearer/Basic token pattern: "Bearer <token>" or "Basic <token>"
    TOKEN_PATTERN = /\b(Bearer|Basic|API-Key)\s+\S+/i

    module_function

    # Deep-redacts sensitive keys from a hash.
    # @param hash [Hash] the hash to filter
    # @return [Hash] a copy with sensitive values replaced by "[FILTERED]"
    def filter_hash(hash)
      return hash unless hash.is_a?(Hash)

      hash.each_with_object({}) do |(key, value), filtered|
        str_key = key.to_s.downcase
        filtered[key] = if SENSITIVE_KEYS.include?(str_key)
                          FILTERED
                        elsif value.is_a?(Hash)
                          filter_hash(value)
                        elsif value.is_a?(String)
                          filter_string(value)
                        else
                          value
                        end
      end
    end

    # Redacts Bearer/Basic/API-Key token patterns in a string.
    # @param str [String] the string to filter
    # @return [String] the filtered string
    def filter_string(str)
      return str unless str.is_a?(String)

      str.gsub(TOKEN_PATTERN, '\1 [FILTERED]')
    end
  end
end
