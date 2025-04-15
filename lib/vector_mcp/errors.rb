# frozen_string_literal: true

module VectorMCP
  # Base error class for VectorMCP
  class Error < StandardError; end

  # Base class for JSON-RPC protocol errors
  class ProtocolError < Error
    attr_reader :code, :message, :data, :request_id

    def initialize(message, code: -32_600, details: nil, request_id: nil)
      super(message)
      @code = code
      @message = message
      @details = details
      @request_id = request_id
    end

    def details
      @details || {}
    end
  end

  # Standard JSON-RPC error classes

  # Parse error (-32700): Invalid JSON was received by the server.
  class ParseError < ProtocolError
    def initialize(message = "Parse error", details: nil, request_id: nil)
      super(message, code: -32_700, details: details, request_id: request_id)
    end
  end

  # Invalid Request (-32600): The JSON sent is not a valid Request object.
  class InvalidRequestError < ProtocolError
    def initialize(message = "Invalid Request", details: nil, request_id: nil)
      super(message, code: -32_600, details: details, request_id: request_id)
    end
  end

  # Method not found (-32601): The method does not exist / is not available.
  class MethodNotFoundError < ProtocolError
    def initialize(method, details: nil, request_id: nil)
      super("Method not found: #{method}", code: -32_601, details: details, request_id: request_id)
    end
  end

  # Invalid params (-32602): Invalid method parameter(s).
  class InvalidParamsError < ProtocolError
    def initialize(message = "Invalid params", details: nil, request_id: nil)
      super(message, code: -32_602, details: details, request_id: request_id)
    end
  end

  # Internal error (-32603): Internal JSON-RPC error.
  class InternalError < ProtocolError
    def initialize(message = "Internal error", details: nil, request_id: nil)
      super(message, code: -32_603, details: details, request_id: request_id)
    end
  end

  # Server error (-32000 to -32099): Reserved for implementation-defined server-errors.
  class ServerError < ProtocolError
    def initialize(message = "Server error", code: -32_000, details: nil, request_id: nil)
      # Ensure the code is within the reserved range
      unless (-32_000..-32_099).cover?(code)
        warn "Server error code #{code} is outside of the reserved range (-32000 to -32099). Using -32000 instead."
        code = -32_000
      end
      super
    end
  end

  # Session not initialized (-32002): Received a request before initialization completed.
  class InitializationError < ServerError
    def initialize(message = "Server not initialized", details: nil, request_id: nil)
      super(message, code: -32_002, details: details, request_id: request_id)
    end
  end

  # Not Found (-32001): Requested resource not found.
  class NotFoundError < ServerError
    def initialize(message = "Not Found", details: nil, request_id: nil)
      super(message, code: -32_001, details: details, request_id: request_id)
    end
  end
end
