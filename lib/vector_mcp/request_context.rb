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

    # Create a minimal request context for non-HTTP transports.
    # This is useful for stdio and other command-line transports.
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

    # Create a request context from a Rack environment.
    # This is a convenience method for HTTP-based transports.
    #
    # @param rack_env [Hash] The Rack environment hash
    # @param transport_type [String] The transport type identifier
    # @return [RequestContext] A request context populated from the Rack environment
    def self.from_rack_env(rack_env, transport_type)
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

    # Normalize headers to ensure consistent format.
    #
    # @param headers [Hash] Raw headers hash
    # @return [Hash] Normalized headers hash
    def normalize_headers(headers)
      return {} unless headers.is_a?(Hash)

      headers.transform_keys(&:to_s).transform_values { |v| v.nil? ? "" : v.to_s }
    end

    # Normalize parameters to ensure consistent format.
    #
    # @param params [Hash] Raw parameters hash
    # @return [Hash] Normalized parameters hash
    def normalize_params(params)
      return {} unless params.is_a?(Hash)

      params.transform_keys(&:to_s).transform_values { |v| v.nil? ? "" : v.to_s }
    end

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
