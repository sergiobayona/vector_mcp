# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module VectorMCP
  module Browser
    # Browser automation tools for VectorMCP
    # These tools communicate with the Chrome extension via HTTP endpoints
    module Tools
      # Base class for browser tools
      class Base
        attr_reader :server_host, :server_port, :logger

        def initialize(server_host: "localhost", server_port: 8000, logger: nil)
          @server_host = server_host
          @server_port = server_port
          @logger = logger || VectorMCP.logger
        end

        private

        # Make HTTP request to browser endpoint
        def make_browser_request(endpoint, params = {})
          uri = URI("http://#{server_host}:#{server_port}/browser/#{endpoint}")
          
          http = Net::HTTP.new(uri.host, uri.port)
          http.open_timeout = 5
          http.read_timeout = 30
          
          request = Net::HTTP::Post.new(uri)
          request["Content-Type"] = "application/json"
          request.body = params.to_json
          
          response = http.request(request)
          
          case response.code.to_i
          when 200
            JSON.parse(response.body)
          when 503
            raise ExtensionNotConnectedError, "Chrome extension not connected"
          when 408
            raise TimeoutError, "Browser operation timed out"
          else
            error_data = JSON.parse(response.body) rescue { "error" => "Unknown error" }
            raise OperationError, error_data["error"] || "Browser operation failed"
          end
        rescue Net::OpenTimeout, Net::ReadTimeout
          raise TimeoutError, "Request to browser server timed out"
        rescue Errno::ECONNREFUSED
          raise ExtensionNotConnectedError, "Cannot connect to browser server"
        end
      end

      # Navigation tool
      class Navigate < Base
        def call(arguments, session_context = nil)
          url = arguments["url"]
          include_snapshot = arguments.fetch("include_snapshot", false)
          
          params = { url: url, include_snapshot: include_snapshot }
          result = make_browser_request("navigate", params)
          
          if result["success"]
            response = { url: result["result"]["url"] }
            response[:snapshot] = result["result"]["snapshot"] if result["result"]["snapshot"]
            response
          else
            raise OperationError, result["error"]
          end
        end
      end

      # Click tool
      class Click < Base
        def call(arguments, session_context = nil)
          selector = arguments["selector"]
          coordinate = arguments["coordinate"]
          include_snapshot = arguments.fetch("include_snapshot", true)
          
          params = { 
            selector: selector,
            coordinate: coordinate,
            include_snapshot: include_snapshot
          }
          result = make_browser_request("click", params)
          
          if result["success"]
            response = { success: true }
            response[:snapshot] = result["result"]["snapshot"] if result["result"] && result["result"]["snapshot"]
            response
          else
            raise OperationError, result["error"]
          end
        end
      end

      # Type tool
      class Type < Base
        def call(arguments, session_context = nil)
          text = arguments["text"]
          selector = arguments["selector"]
          coordinate = arguments["coordinate"]
          include_snapshot = arguments.fetch("include_snapshot", true)
          
          params = {
            text: text,
            selector: selector,
            coordinate: coordinate,
            include_snapshot: include_snapshot
          }
          result = make_browser_request("type", params)
          
          if result["success"]
            response = { success: true }
            response[:snapshot] = result["result"]["snapshot"] if result["result"] && result["result"]["snapshot"]
            response
          else
            raise OperationError, result["error"]
          end
        end
      end

      # Snapshot tool
      class Snapshot < Base
        def call(arguments, session_context = nil)
          result = make_browser_request("snapshot", {})
          
          if result["success"]
            { snapshot: result["result"]["snapshot"] }
          else
            raise OperationError, result["error"]
          end
        end
      end

      # Screenshot tool
      class Screenshot < Base
        def call(arguments, session_context = nil)
          result = make_browser_request("screenshot", {})
          
          if result["success"]
            # Get the screenshot data URL
            screenshot_data = result["result"]["screenshot"]
            
            # Remove data:image/png;base64, prefix if present
            if screenshot_data.start_with?("data:image/")
              base64_data = screenshot_data.split(",", 2)[1]
            else
              base64_data = screenshot_data
            end
            
            { 
              type: "image",
              data: base64_data,
              mimeType: "image/png"
            }
          else
            raise OperationError, result["error"]
          end
        end
      end

      # Console logs tool
      class Console < Base
        def call(arguments, session_context = nil)
          result = make_browser_request("console", {})
          
          if result["success"]
            { logs: result["result"]["logs"] }
          else
            raise OperationError, result["error"]
          end
        end
      end

      # Wait tool
      class Wait < Base
        def call(arguments, session_context = nil)
          duration = arguments.fetch("duration", 1000)
          
          result = make_browser_request("wait", { duration: duration })
          
          if result["success"]
            { message: result["result"] }
          else
            raise OperationError, result["error"]
          end
        end
      end
    end
  end
end