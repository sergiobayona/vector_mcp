# frozen_string_literal: true

module VectorMCP
  # Base error class for all VectorMCP specific errors.
  class Error < StandardError; end

  # Base class for **all** JSON-RPC 2.0 errors that the VectorMCP library can
  # emit.  It mirrors the structure defined by the JSON-RPC spec and adds a
  # flexible `details` field that implementers may use to attach structured,
  # implementation-specific metadata to an error payload.
  #
  # @!attribute [r] code
  #   @return [Integer] The JSON-RPC error code.
  # @!attribute [r] message
  #   @return [String] A short description of the error.
  # @!attribute [rw] request_id
  #   @return [String, Integer, nil] The ID of the request that caused this error, if applicable.
  # @!attribute [r] details
  #   @return [Hash, nil] Additional implementation-specific details for the error (optional).
  class ProtocolError < Error
    attr_accessor :request_id
    attr_reader :code, :message, :details

    # Initializes a new ProtocolError.
    #
    # @param message [String] The error message.
    # @param code [Integer] The JSON-RPC error code.
    # @param details [Hash, nil] Additional details for the error (optional).
    # @param request_id [String, Integer, nil] The ID of the originating request.
    def initialize(message, code: -32_600, details: nil, request_id: nil)
      VectorMCP.logger.debug("Initializing ProtocolError with code: #{code}")
      @code = code
      @message = message
      @details = details # NOTE: `data` in JSON-RPC is often used for this purpose.
      @request_id = request_id
      super(message)
    end

    # Allows setting the request_id after initialization if it wasn't known at first.
    attr_writer :request_id
  end

  # Standard JSON-RPC error classes

  # Represents a JSON-RPC Parse error (-32700).
  # Indicates invalid JSON was received by the server.
  class ParseError < ProtocolError
    # @param message [String] The error message.
    # @param details [Hash, nil] Additional details for the error (optional).
    # @param request_id [String, Integer, nil] The ID of the originating request.
    def initialize(message = "Parse error", details: nil, request_id: nil)
      super(message, code: -32_700, details: details, request_id: request_id)
    end
  end

  # Represents a JSON-RPC Invalid Request error (-32600).
  # Indicates the JSON sent is not a valid Request object.
  class InvalidRequestError < ProtocolError
    # @param message [String] The error message.
    # @param details [Hash, nil] Additional details for the error (optional).
    # @param request_id [String, Integer, nil] The ID of the originating request.
    def initialize(message = "Invalid Request", details: nil, request_id: nil)
      super(message, code: -32_600, details: details, request_id: request_id)
    end
  end

  # Represents a JSON-RPC Method Not Found error (-32601).
  # Indicates the method does not exist or is not available.
  class MethodNotFoundError < ProtocolError
    # @param method [String] The name of the method that was not found.
    # @param details [Hash, nil] Additional details for the error (optional).
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
    # @param details [Hash, nil] Additional details for the error (optional).
    # @param request_id [String, Integer, nil] The ID of the originating request.
    def initialize(message = "Invalid params", details: nil, request_id: nil)
      super(message, code: -32_602, details: details, request_id: request_id)
    end
  end

  # Represents a JSON-RPC Internal error (-32603).
  # Indicates an internal error in the JSON-RPC server.
  class InternalError < ProtocolError
    # @param message [String] The error message.
    # @param details [Hash, nil] Additional details for the error (optional).
    # @param request_id [String, Integer, nil] The ID of the originating request.
    def initialize(message = "Internal error", details: nil, request_id: nil)
      super(message, code: -32_603, details: details, request_id: request_id)
    end
  end

  # Represents a JSON-RPC server-defined error (codes -32000 to -32099).
  class ServerError < ProtocolError
    # @param message [String] The error message.
    # @param code [Integer] The server-defined error code. Must be between -32099 and -32000. If the
    #   supplied value falls outside this range it will be coerced to **-32000** in order to comply
    #   with the JSON-RPC 2.0 specification.
    # @param details [Hash, nil] Additional details for the error (optional).
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
    # @param details [Hash, nil] Additional details for the error (optional).
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
    # @param details [Hash, nil] Additional details for the error (optional).
    # @param request_id [String, Integer, nil] The ID of the originating request.
    def initialize(message = "Not Found", details: nil, request_id: nil)
      VectorMCP.logger.debug("Initializing NotFoundError with code: -32001")
      super(message, code: -32_001, details: details, request_id: request_id)
    end
  end

  # --- Sampling Specific Errors ---
  # These are errors that can occur when a server initiates a `sampling/createMessage` request.

  # Base class for sampling-related errors originating from client or transport during a server-initiated sample request.
  class SamplingError < ProtocolError
    # @param message [String] The error message.
    # @param code [Integer] JSON-RPC error code (typically from client response, or server defined for timeouts etc).
    # @param details [Object, nil] Optional additional error data from client or transport.
    # @param request_id [String, Integer, nil] The ID of the `sampling/createMessage` request.
    def initialize(message = "An error occurred during sampling.", code: -32_050, details: nil, request_id: nil)
      # Using -32050 as a generic base for sampling errors from server's perspective.
      # Specific errors from client might have different codes.
      super
    end
  end

  # Raised when a server-initiated sampling request times out waiting for a client response.
  class SamplingTimeoutError < SamplingError
    def initialize(message = "Timeout waiting for client response to sampling request.", details: nil, request_id: nil)
      super(message, code: -32_051, details: details, request_id: request_id) # Server-defined code for this timeout
    end
  end

  # Raised if the client explicitly rejects or denies the sampling request (e.g., user vetoed).
  # This would typically correspond to a specific error response from the client.
  class SamplingRejectedError < SamplingError
    def initialize(message = "Client rejected the sampling request.", code: -32_052, details: nil, request_id: nil)
      # This code might be overridden by the actual error code from the client if available.
      super
    end
  end

  # Placeholder for other specific sampling errors that might be defined based on client responses.
  # class SpecificSamplingClientError < SamplingError
  #   def initialize(message, client_code:, client_details:, request_id: nil)
  #     super(message, code: client_code, details: client_details, request_id: request_id)
  #   end
  # end
end
