# frozen_string_literal: true

module MCPRuby
  # Base error class for MCPRuby
  class Error < StandardError; end

  # Error during MCP protocol interactions
  class ProtocolError < Error
    attr_reader :code, :request_id, :details

    def initialize(message, code:, request_id: nil, details: nil)
      super(message)
      @code = code
      @request_id = request_id
      @details = details
    end
  end

  # Specific protocol errors
  class ParseError < ProtocolError
    def initialize(message = "Parse error", request_id: nil, details: nil)
      super(message, code: -32_700, request_id: request_id, details: details)
    end
  end

  class InvalidRequestError < ProtocolError
    def initialize(message = "Invalid Request", request_id: nil, details: nil)
      super(message, code: -32_600, request_id: request_id, details: details)
    end
  end

  class MethodNotFoundError < ProtocolError
    def initialize(method_name, request_id: nil)
      super("Method not found", code: -32_601, request_id: request_id, details: { method: method_name })
    end
  end

  class InvalidParamsError < ProtocolError
    def initialize(message = "Invalid params", request_id: nil, details: nil)
      super(message, code: -32_602, request_id: request_id, details: details)
    end
  end

  class InternalError < ProtocolError
    def initialize(message = "Internal server error", request_id: nil, details: nil)
      super(message, code: -32_603, request_id: request_id, details: details)
    end
  end

  # For application-level errors (-32000 to -32099)
  class ServerError < ProtocolError
    def initialize(message = "Server error", code: -32_000, request_id: nil, details: nil)
      super
    end
  end

  class InitializationError < ServerError
    def initialize(message = "Server not initialized", request_id: nil, details: nil)
      super(message, code: -32_002, request_id: request_id, details: details) # Example custom code
    end
  end

  class NotFoundError < ServerError
    def initialize(message = "Not Found", request_id: nil, details: nil)
      super(message, code: -32_001, request_id: request_id, details: details) # Example custom code
    end
  end

  # Add more specific errors as needed (e.g., ToolError, ResourceError)
end
