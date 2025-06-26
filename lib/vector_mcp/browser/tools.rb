# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "securerandom"

module VectorMCP
  module Browser
    # Browser automation tools for VectorMCP
    # These tools communicate with the Chrome extension via HTTP endpoints
    module Tools
      # Base class for browser tools
      class Base
        attr_reader :server_host, :server_port, :logger, :operation_logger

        def initialize(server_host: "localhost", server_port: 8000, logger: nil)
          @server_host = server_host
          @server_port = server_port
          @logger = logger || VectorMCP.logger
          @operation_logger = VectorMCP.logger_for("browser.operations")
        end

        private

        # Make HTTP request to browser endpoint with comprehensive logging
        def make_browser_request(endpoint, params = {})
          operation_id = SecureRandom.uuid
          start_time = Time.now
          
          # Log operation start
          @operation_logger.info("Browser operation started", context: {
            operation_id: operation_id,
            endpoint: endpoint,
            tool: self.class.name.split("::").last,
            params: sanitize_params_for_logging(params),
            server: "#{server_host}:#{server_port}",
            timestamp: start_time.iso8601
          })
          
          uri = URI("http://#{server_host}:#{server_port}/browser/#{endpoint}")
          
          http = Net::HTTP.new(uri.host, uri.port)
          http.open_timeout = 5
          http.read_timeout = 30
          
          request = Net::HTTP::Post.new(uri)
          request["Content-Type"] = "application/json"
          request.body = params.to_json
          
          response = http.request(request)
          execution_time = ((Time.now - start_time) * 1000).round(2)
          
          case response.code.to_i
          when 200
            result = JSON.parse(response.body)
            
            # Log successful operation
            @operation_logger.info("Browser operation completed", context: {
              operation_id: operation_id,
              endpoint: endpoint,
              tool: self.class.name.split("::").last,
              success: true,
              execution_time_ms: execution_time,
              response_size: response.body.length,
              timestamp: Time.now.iso8601
            })
            
            result
          when 503
            @operation_logger.warn("Browser operation failed - extension not connected", context: {
              operation_id: operation_id,
              endpoint: endpoint,
              tool: self.class.name.split("::").last,
              error: "Extension not connected",
              execution_time_ms: execution_time,
              timestamp: Time.now.iso8601
            })
            raise ExtensionNotConnectedError, "Chrome extension not connected"
          when 408
            @operation_logger.warn("Browser operation timed out", context: {
              operation_id: operation_id,
              endpoint: endpoint,
              tool: self.class.name.split("::").last,
              error: "Operation timeout",
              execution_time_ms: execution_time,
              timestamp: Time.now.iso8601
            })
            raise TimeoutError, "Browser operation timed out"
          else
            error_data = JSON.parse(response.body) rescue { "error" => "Unknown error" }
            error_message = error_data["error"] || "Browser operation failed"
            
            @operation_logger.error("Browser operation failed", context: {
              operation_id: operation_id,
              endpoint: endpoint,
              tool: self.class.name.split("::").last,
              error: error_message,
              status_code: response.code.to_i,
              execution_time_ms: execution_time,
              timestamp: Time.now.iso8601
            })
            
            raise OperationError, error_message
          end
        rescue Net::OpenTimeout, Net::ReadTimeout => e
          execution_time = ((Time.now - start_time) * 1000).round(2)
          
          @operation_logger.error("Browser operation network timeout", context: {
            operation_id: operation_id,
            endpoint: endpoint,
            tool: self.class.name.split("::").last,
            error: e.message,
            error_type: e.class.name,
            execution_time_ms: execution_time,
            timestamp: Time.now.iso8601
          })
          
          raise TimeoutError, "Request to browser server timed out"
        rescue Errno::ECONNREFUSED
          raise ExtensionNotConnectedError, "Cannot connect to browser server"
        end

        # Sanitize parameters for logging (remove sensitive data)
        def sanitize_params_for_logging(params)
          return params unless params.is_a?(Hash)

          sanitized = params.dup
          
          # Remove or mask sensitive fields
          sensitive_fields = %w[password token secret key authorization auth]
          sensitive_fields.each do |field|
            if sanitized.key?(field)
              sanitized[field] = "[REDACTED]"
            end
          end

          # Truncate very long text values to prevent log bloat
          sanitized.each do |key, value|
            if value.is_a?(String) && value.length > 500
              sanitized[key] = "#{value[0...500]}...[TRUNCATED]"
            end
          end

          sanitized
        end
      end

      # Navigation tool
      class Navigate < Base
        def call(arguments, session_context = nil)
          url = arguments["url"]
          include_snapshot = arguments.fetch("include_snapshot", false)
          
          # Log navigation intent
          @operation_logger.info("Browser navigation initiated", context: {
            tool: "Navigate",
            url: url,
            include_snapshot: include_snapshot,
            user_id: session_context&.user&.[](:id),
            timestamp: Time.now.iso8601
          })
          
          params = { url: url, include_snapshot: include_snapshot }
          result = make_browser_request("navigate", params)
          
          if result["success"]
            response = { url: result["result"]["url"] }
            response[:snapshot] = result["result"]["snapshot"] if result["result"]["snapshot"]
            
            # Log successful navigation
            @operation_logger.info("Browser navigation completed", context: {
              tool: "Navigate",
              url: url,
              final_url: result["result"]["url"],
              snapshot_included: !result["result"]["snapshot"].nil?,
              user_id: session_context&.user&.[](:id),
              timestamp: Time.now.iso8601
            })
            
            response
          else
            # Log navigation failure
            @operation_logger.error("Browser navigation failed", context: {
              tool: "Navigate",
              url: url,
              error: result["error"],
              user_id: session_context&.user&.[](:id),
              timestamp: Time.now.iso8601
            })
            
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
          
          # Log click intent
          @operation_logger.info("Browser click initiated", context: {
            tool: "Click",
            selector: selector,
            coordinate: coordinate,
            include_snapshot: include_snapshot,
            user_id: session_context&.user&.[](:id),
            timestamp: Time.now.iso8601
          })
          
          params = { 
            selector: selector,
            coordinate: coordinate,
            include_snapshot: include_snapshot
          }
          result = make_browser_request("click", params)
          
          if result["success"]
            response = { success: true }
            response[:snapshot] = result["result"]["snapshot"] if result["result"] && result["result"]["snapshot"]
            
            # Log successful click
            @operation_logger.info("Browser click completed", context: {
              tool: "Click",
              selector: selector,
              coordinate: coordinate,
              snapshot_included: !result["result"]["snapshot"].nil?,
              user_id: session_context&.user&.[](:id),
              timestamp: Time.now.iso8601
            })
            
            response
          else
            # Log click failure
            @operation_logger.error("Browser click failed", context: {
              tool: "Click",
              selector: selector,
              coordinate: coordinate,
              error: result["error"],
              user_id: session_context&.user&.[](:id),
              timestamp: Time.now.iso8601
            })
            
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
          
          # Log typing intent (with text sanitization for security)
          @operation_logger.info("Browser typing initiated", context: {
            tool: "Type",
            text_length: text&.length || 0,
            selector: selector,
            coordinate: coordinate,
            include_snapshot: include_snapshot,
            user_id: session_context&.user&.[](:id),
            timestamp: Time.now.iso8601
          })
          
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
            
            # Log successful typing
            @operation_logger.info("Browser typing completed", context: {
              tool: "Type",
              text_length: text&.length || 0,
              selector: selector,
              coordinate: coordinate,
              snapshot_included: !result["result"]["snapshot"].nil?,
              user_id: session_context&.user&.[](:id),
              timestamp: Time.now.iso8601
            })
            
            response
          else
            # Log typing failure
            @operation_logger.error("Browser typing failed", context: {
              tool: "Type",
              text_length: text&.length || 0,
              selector: selector,
              coordinate: coordinate,
              error: result["error"],
              user_id: session_context&.user&.[](:id),
              timestamp: Time.now.iso8601
            })
            
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