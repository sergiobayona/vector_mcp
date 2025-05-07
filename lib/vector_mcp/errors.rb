# frozen_string_literal: true

module VectorMCP
  # Base error class for all VectorMCP specific errors.
  class Error < StandardError; end

  # Base class for JSON-RPC 2.0 protocol errors.
  #
  # @attr_reader code [Integer] The JSON-RPC error code.
  # @attr_reader message [String] A string providing a short description of the error.
  # @attr_reader data [Object, nil] A primitive or structured value that contains additional information about the error. This may be omitted.
  # @attr_reader request_id [String, Integer, nil] The ID of the request that caused this error, if applicable.
  # @attr_reader details [Hash, nil] Additional implementation-specific details for the error.
  class ProtocolError < Error
    attr_reader :code, :message, :data, :request_id

    # Initializes a new ProtocolError.
    #
    # @param message [String] The error message.
    # @param code [Integer] The JSON-RPC error code.
    # @param details [Hash, nil] Additional details for the error.
    # @param request_id [String, Integer, nil] The ID of the originating request.
    def initialize(message, code: -32_600, details: nil, request_id: nil)
      VectorMCP.logger.debug("Initializing ProtocolError with code: #{code}")
      @code = code
      @message = message
      @details = details # Note: `data` in JSON-RPC is often used for this purpose.
      @request_id = request_id
      super(message)
    end

    attr_reader :details
  end

  # Standard JSON-RPC error classes

  # Represents a JSON-RPC Parse error (-32700).
  # Indicates invalid JSON was received by the server.
  class ParseError < ProtocolError
    # @param message [String] The error message.
    # @param details [Hash, nil] Additional details for the error.
    # @param request_id [String, Integer, nil] The ID of the originating request.
    def initialize(message = "Parse error", details: nil, request_id: nil)
      super(message, code: -32_700, details: details, request_id: request_id)
    end
  end

  # Represents a JSON-RPC Invalid Request error (-32600).
  # Indicates the JSON sent is not a valid Request object.
  class InvalidRequestError < ProtocolError
    # @param message [String] The error message.
    # @param details [Hash, nil] Additional details for the error.
    # @param request_id [String, Integer, nil] The ID of the originating request.
    def initialize(message = "Invalid Request", details: nil, request_id: nil)
      super(message, code: -32_600, details: details, request_id: request_id)
    end
  end

  # Represents a JSON-RPC Method Not Found error (-32601).
  # Indicates the method does not exist or is not available.
  class MethodNotFoundError < ProtocolError
    # @param method [String] The name of the method that was not found.
    # @param details [Hash, nil] Additional details for the error.
    # @param request_id [String, Integer, nil] The ID of the originating request.
    def initialize(method, details: nil, request_id: nil)
      details ||= { method_name: method }
      super("Method not found: #{method}", code: -32_601, details: details, request_id: request_id)
    end
  end

  # Represents a JSON-RPC Invalid Params error (-32602).
  # Indicates invalid method parameter(s).
  class InvalidParamsError < ProtocolError
    # @param message [String] The error message.
    # @param details [Hash, nil] Additional details for the error.
    # @param request_id [String, Integer, nil] The ID of the originating request.
    def initialize(message = "Invalid params", details: nil, request_id: nil)
      super(message, code: -32_602, details: details, request_id: request_id)
    end
  end

  # Represents a JSON-RPC Internal error (-32603).
  # Indicates an internal error in the JSON-RPC server.
  class InternalError < ProtocolError
    # @param message [String] The error message.
    # @param details [Hash, nil] Additional details for the error.
    # @param request_id [String, Integer, nil] The ID of the originating request.
    def initialize(message = "Internal error", details: nil, request_id: nil)
      super(message, code: -32_603, details: details, request_id: request_id)
    end
  end

  # Represents a JSON-RPC server-defined error (codes -32000 to -32099).
  class ServerError < ProtocolError
    # @param message [String] The error message.
    # @param code [Integer] The server-defined error code. Must be between -32099 and -32000.
    # @param details [Hash, nil] Additional details for the error.
    # @param request_id [String, Integer, nil] The ID of the originating request.
    def initialize(message = "Server error", code: -32_000, details: nil, request_id: nil)
      VectorMCP.logger.debug("Initializing ServerError with code: #{code}")
      unless (-32_099..-32_000).cover?(code)
        warn "Server error code #{code} is outside of the reserved range (-32099 to -32000). Using -32000 instead."
        code = -32_000
      end
      super
    end
  end

  # Represents an error indicating a request was received before server initialization completed (-32002).
  class InitializationError < ServerError
    # @param message [String] The error message.
    # @param details [Hash, nil] Additional details for the error.
    # @param request_id [String, Integer, nil] The ID of the originating request.
    def initialize(message = "Server not initialized", details: nil, request_id: nil)
      super(message, code: -32_002, details: details, request_id: request_id)
    end
  end

  # Represents an error indicating a requested resource or entity was not found (-32001).
  # Note: This uses a code typically outside the strict JSON-RPC server error range,
  # but is common in practice for "Not Found" scenarios.
  class NotFoundError < ProtocolError
    # @param message [String] The error message.
    # @param details [Hash, nil] Additional details for the error.
    # @param request_id [String, Integer, nil] The ID of the originating request.
    def initialize(message = "Not Found", details: nil, request_id: nil)
      VectorMCP.logger.debug("Initializing NotFoundError with code: -32001")
      super(message, code: -32_001, details: details, request_id: request_id)
    end
  end
end
