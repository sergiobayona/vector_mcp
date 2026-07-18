# frozen_string_literal: true

module VectorMCP
  # Encapsulates request-specific data for MCP sessions.
  # This provides a formal interface for transports to populate request context
  # and for handlers to access request data without coupling to session internals.
  #
  # @attr_reader headers [Hash] HTTP headers from the request
  # @attr_reader params [Hash] Query parameters from the request
  # @attr_reader method [String, nil] HTTP method (GET, POST, etc.) or transport-specific method
  # @attr_reader path [String, nil] Request path or transport-specific path
  # @attr_reader transport_metadata [Hash] Transport-specific metadata
  class RequestContext
    attr_reader :headers, :params, :method, :path, :transport_metadata

    # Initialize a new request context with the provided data.
    #
    # @param headers [Hash] HTTP headers from the request (default: {})
    # @param params [Hash] Query parameters from the request (default: {})
    # @param method [String, nil] HTTP method or transport-specific method (default: nil)
    # @param path [String, nil] Request path or transport-specific path (default: nil)
    # @param transport_metadata [Hash] Transport-specific metadata (default: {})
    def initialize(headers: {}, params: {}, method: nil, path: nil, transport_metadata: {})
      @headers = normalize_headers(headers).freeze
      @params = normalize_params(params).freeze
      @method = method&.to_s&.freeze
      @path = path&.to_s&.freeze
      @transport_metadata = normalize_metadata(transport_metadata).freeze
    end

    # Convert the request context to a hash representation.
    # This is useful for serialization and debugging.
    #
    # @return [Hash] Hash representation of the request context
    def to_h
      {
        headers: @headers,
        params: @params,
        method: @method,
        path: @path,
        transport_metadata: @transport_metadata
      }
    end

    # Check if the request context has any headers.
    #
    # @return [Boolean] True if headers are present, false otherwise
    def headers?
      !@headers.empty?
    end

    # Check if the request context has any parameters.
    #
    # @return [Boolean] True if parameters are present, false otherwise
    def params?
      !@params.empty?
    end

    # Get a specific header value.
    #
    # @param name [String] The header name
    # @return [String, nil] The header value or nil if not found
    def header(name)
      @headers[name.to_s]
    end

    # Get a specific parameter value.
    #
    # @param name [String] The parameter name
    # @return [String, nil] The parameter value or nil if not found
    def param(name)
      @params[name.to_s]
    end

    # Get transport-specific metadata.
    #
    # @param key [String, Symbol] The metadata key
    # @return [Object, nil] The metadata value or nil if not found
    def metadata(key)
      @transport_metadata[key.to_s]
    end

    # Check if this is an HTTP-based transport.
    #
    # @return [Boolean] True if method is an HTTP method and path is present
    def http_transport?
      return false unless @method && @path

      # Check if method is an HTTP method
      http_methods = %w[GET POST PUT DELETE HEAD OPTIONS PATCH TRACE CONNECT]
      http_methods.include?(@method.upcase)
    end

    # Return a new context with the given attributes merged in. Nested hashes
    # (headers, params, transport_metadata) are merged key-wise; scalar
    # attributes are replaced.
    #
    # @param attributes [Hash] attributes to merge
    # @return [RequestContext] a new, merged context
    def merge(attributes)
      current = to_h
      merged = current.dup
      attributes.each do |key, value|
        merged[key] = if value.is_a?(Hash) && current[key].is_a?(Hash)
                        current[key].merge(value)
                      else
                        value
                      end
      end
      RequestContext.new(**merged)
    end

    # Create a minimal request context for non-HTTP transports.
    # This is useful for non-HTTP transports or testing contexts.
    #
    # @param transport_type [String] The transport type identifier
    # @return [RequestContext] A minimal request context
    def self.minimal(transport_type)
      new(
        headers: {},
        params: {},
        method: transport_type.to_s.upcase,
        path: "/",
        transport_metadata: { transport_type: transport_type.to_s }
      )
    end

    # Coerce an arbitrary request representation into a RequestContext.
    # This is the single boundary where legacy request shapes (raw Rack
    # environments, `{headers:, params:}` hashes with symbol or string keys)
    # are converted; everything downstream of authentication trusts this type.
    #
    # @param request [RequestContext, Hash] the request to coerce
    # @param transport_type [String] transport identifier used when building from a Rack env
    # @return [RequestContext]
    # @raise [ArgumentError] if the input cannot be coerced
    def self.coerce(request, transport_type = "http")
      case request
      when RequestContext
        request
      when Hash
        return from_rack_env(request, transport_type) if request.key?("REQUEST_METHOD")

        from_normalized_hash(request)
      else
        raise ArgumentError, "Cannot coerce #{request.class} into a VectorMCP::RequestContext"
      end
    end

    # Build a context from a legacy `{headers:, params:, ...}` hash with either
    # symbol or string keys.
    # @api private
    def self.from_normalized_hash(hash)
      fetch = ->(key) { hash[key] || hash[key.to_s] }
      new(
        headers: fetch.call(:headers) || {},
        params: fetch.call(:params) || {},
        method: fetch.call(:method),
        path: fetch.call(:path),
        transport_metadata: fetch.call(:transport_metadata) || {}
      )
    end
    private_class_method :from_normalized_hash

    # Hash-style read access for compatibility with custom authentication
    # handlers written against the legacy `{headers:, params:}` request hash.
    #
    # @param key [String, Symbol] one of :headers, :params, :method, :path, :transport_metadata
    # @return [Object, nil]
    def [](key)
      hash_view[key.to_sym]
    end

    # @param key [String, Symbol] the top-level key to check
    # @return [Boolean]
    def key?(key)
      hash_view.key?(key.to_sym)
    end
    alias has_key? key?
    alias include? key?
    alias member? key?

    # Dig into the context like a nested hash, e.g. `context.dig(:headers, "X-API-Key")`.
    #
    # @param key [String, Symbol] the top-level key
    # @param rest [Array] further keys passed to the nested value's #dig
    # @return [Object, nil]
    def dig(key, *rest)
      value = self[key]
      return value if rest.empty?

      value&.dig(*rest)
    end

    # Create a request context from a Rack environment.
    # This is a convenience method for HTTP-based transports.
    #
    # @param rack_env [Hash] The Rack environment hash
    # @param transport_type [String] The transport type identifier
    # @return [RequestContext] A request context populated from the Rack environment
    def self.from_rack_env(rack_env, transport_type)
      # Handle nil rack_env by returning a minimal context
      return minimal(transport_type) if rack_env.nil?

      new(
        headers: VectorMCP::Util.extract_headers_from_rack_env(rack_env),
        params: VectorMCP::Util.extract_params_from_rack_env(rack_env),
        method: rack_env["REQUEST_METHOD"],
        path: rack_env["PATH_INFO"],
        transport_metadata: {
          transport_type: transport_type.to_s,
          remote_addr: rack_env["REMOTE_ADDR"],
          user_agent: rack_env["HTTP_USER_AGENT"],
          content_type: rack_env["CONTENT_TYPE"]
        }
      )
    end

    # String representation of the request context.
    #
    # @return [String] String representation for debugging
    def to_s
      "<RequestContext method=#{@method} path=#{@path} headers=#{@headers.keys.size} params=#{@params.keys.size}>"
    end

    # Detailed string representation for debugging.
    #
    # @return [String] Detailed string representation
    def inspect
      "#<#{self.class.name}:0x#{object_id.to_s(16)} " \
        "method=#{@method.inspect} path=#{@path.inspect} " \
        "headers=#{@headers.inspect} params=#{@params.inspect} " \
        "transport_metadata=#{@transport_metadata.inspect}>"
    end

    private

    # Memoized nested-hash view backing the hash-style read accessors.
    def hash_view
      @hash_view ||= to_h.freeze
    end

    # Normalize a headers/params hash to string keys and string values.
    #
    # @param hash [Hash] Raw hash
    # @return [Hash] Normalized hash
    def normalize_string_map(hash)
      return {} unless hash.is_a?(Hash)

      hash.transform_keys(&:to_s).transform_values { |v| v.nil? ? "" : v.to_s }
    end
    alias normalize_headers normalize_string_map
    alias normalize_params normalize_string_map

    # Normalize transport metadata to ensure consistent format.
    #
    # @param metadata [Hash] Raw metadata hash
    # @return [Hash] Normalized metadata hash
    def normalize_metadata(metadata)
      return {} unless metadata.is_a?(Hash)

      metadata.transform_keys(&:to_s)
    end
  end
end
