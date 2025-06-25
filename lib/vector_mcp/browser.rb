# frozen_string_literal: true

# Browser automation module for VectorMCP
# Provides a framework for browser automation via Chrome extension communication
module VectorMCP
  module Browser
    # Base error class for browser automation errors
    class Error < StandardError; end

    # Error raised when browser extension is not connected
    class ExtensionNotConnectedError < Error; end

    # Error raised when browser operation times out
    class TimeoutError < Error; end

    # Error raised when browser operation fails
    class OperationError < Error; end
  end
end

require_relative "browser/http_server"
require_relative "browser/command_queue"
require_relative "browser/tools"
require_relative "browser/server_extension"