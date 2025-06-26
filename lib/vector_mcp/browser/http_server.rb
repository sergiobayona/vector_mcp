# frozen_string_literal: true

require "json"
require "securerandom"
require "concurrent-ruby"

module VectorMCP
  module Browser
    # HTTP server component that handles browser automation commands
    # This extends the existing SSE transport to add browser automation endpoints
    class HttpServer
      attr_reader :logger, :command_queue

      def initialize(logger, security_middleware: nil)
        @logger = logger
        @security_logger = VectorMCP.logger_for("security.browser")
        @security_middleware = security_middleware
        @command_queue = CommandQueue.new(logger)
        @extension_connected = false
        @extension_last_ping = nil
      end

      # Check if Chrome extension is connected
      def extension_connected?
        return false unless @extension_connected
        return true unless @extension_last_ping

        # Consider extension disconnected if no ping in last 30 seconds
        still_connected = Time.now - @extension_last_ping < 30
        
        # Log disconnection event
        if @extension_connected && !still_connected
          @extension_connected = false
          @security_logger.warn("Chrome extension disconnected", context: {
            last_ping: @extension_last_ping&.iso8601,
            timeout_seconds: 30,
            timestamp: Time.now.iso8601
          })
        end
        
        still_connected
      end

      # Handle browser automation endpoints
      def handle_browser_request(path, env)
        case path
        when "/browser/ping"
          handle_extension_ping(env)
        when "/browser/poll"
          handle_extension_poll(env)
        when "/browser/result"
          handle_extension_result(env)
        when "/browser/navigate"
          handle_navigate_command(env)
        when "/browser/click"
          handle_click_command(env)
        when "/browser/type"
          handle_type_command(env)
        when "/browser/snapshot"
          handle_snapshot_command(env)
        when "/browser/screenshot"
          handle_screenshot_command(env)
        when "/browser/console"
          handle_console_command(env)
        when "/browser/wait"
          handle_wait_command(env)
        else
          [404, { "Content-Type" => "text/plain" }, ["Browser endpoint not found"]]
        end
      end

      # Check security for browser automation requests
      def check_security(env, action)
        return { success: true } unless @security_middleware&.security_enabled?

        # Extract request from Rack environment
        request = @security_middleware.normalize_request(env)
        
        # Log security attempt
        @security_logger.info("Browser automation security check", context: {
          action: action,
          ip_address: env["REMOTE_ADDR"],
          user_agent: env["HTTP_USER_AGENT"],
          endpoint: env["PATH_INFO"],
          method: env["REQUEST_METHOD"]
        })
        
        # Process security check
        result = @security_middleware.process_request(request, action: action, resource: nil)
        
        # Log security result
        if result[:success]
          @security_logger.info("Browser automation authorized", context: {
            action: action,
            user_id: result[:session_context]&.user&.[](:id),
            user_role: result[:session_context]&.user&.[](:role),
            ip_address: env["REMOTE_ADDR"]
          })
        else
          @security_logger.warn("Browser automation denied", context: {
            action: action,
            error: result[:error],
            error_code: result[:error_code],
            ip_address: env["REMOTE_ADDR"],
            user_agent: env["HTTP_USER_AGENT"]
          })
        end
        
        result
      end

      private

      # Extension ping endpoint - confirms extension is alive
      def handle_extension_ping(env)
        return method_not_allowed("POST") unless env["REQUEST_METHOD"] == "POST"

        was_connected = @extension_connected
        @extension_connected = true
        @extension_last_ping = Time.now
        
        # Log extension connection events for security monitoring
        if !was_connected
          @security_logger.info("Chrome extension connected", context: {
            ip_address: env["REMOTE_ADDR"],
            user_agent: env["HTTP_USER_AGENT"],
            timestamp: Time.now.iso8601
          })
        end
        
        logger.debug("Chrome extension ping received")

        [200, { "Content-Type" => "application/json" }, [{ status: "ok" }.to_json]]
      end

      # Extension poll endpoint - returns pending commands
      def handle_extension_poll(env)
        return method_not_allowed("GET") unless env["REQUEST_METHOD"] == "GET"

        commands = @command_queue.get_pending_commands
        logger.debug("Extension poll: returning #{commands.size} commands")

        [200, { "Content-Type" => "application/json" }, [{ commands: commands }.to_json]]
      end

      # Extension result endpoint - receives command execution results
      def handle_extension_result(env)
        return method_not_allowed("POST") unless env["REQUEST_METHOD"] == "POST"

        body = read_request_body(env)
        result_data = JSON.parse(body)
        
        command_id = result_data["command_id"]
        success = result_data["success"]
        result = result_data["result"]
        error = result_data["error"]

        logger.debug("Received result for command #{command_id}: success=#{success}")
        
        @command_queue.complete_command(command_id, success, result, error)

        [200, { "Content-Type" => "application/json" }, [{ status: "ok" }.to_json]]
      rescue JSON::ParserError => e
        logger.error("Invalid JSON in extension result: #{e.message}")
        [400, { "Content-Type" => "application/json" }, [{ error: "Invalid JSON" }.to_json]]
      end

      # Browser automation command handlers
      def handle_navigate_command(env)
        return method_not_allowed("POST") unless env["REQUEST_METHOD"] == "POST"
        return extension_not_connected_response unless extension_connected?

        # Security check
        security_result = check_security(env, :navigate)
        return security_error_response(security_result) unless security_result[:success]

        execute_browser_command(env, "navigate")
      end

      def handle_click_command(env)
        return method_not_allowed("POST") unless env["REQUEST_METHOD"] == "POST"
        return extension_not_connected_response unless extension_connected?

        # Security check
        security_result = check_security(env, :click)
        return security_error_response(security_result) unless security_result[:success]

        execute_browser_command(env, "click")
      end

      def handle_type_command(env)
        return method_not_allowed("POST") unless env["REQUEST_METHOD"] == "POST"
        return extension_not_connected_response unless extension_connected?

        # Security check
        security_result = check_security(env, :type)
        return security_error_response(security_result) unless security_result[:success]

        execute_browser_command(env, "type")
      end

      def handle_snapshot_command(env)
        return method_not_allowed("POST") unless env["REQUEST_METHOD"] == "POST"
        return extension_not_connected_response unless extension_connected?

        # Security check
        security_result = check_security(env, :snapshot)
        return security_error_response(security_result) unless security_result[:success]

        execute_browser_command(env, "snapshot")
      end

      def handle_screenshot_command(env)
        return method_not_allowed("POST") unless env["REQUEST_METHOD"] == "POST"
        return extension_not_connected_response unless extension_connected?

        # Security check
        security_result = check_security(env, :screenshot)
        return security_error_response(security_result) unless security_result[:success]

        execute_browser_command(env, "screenshot")
      end

      def handle_console_command(env)
        return method_not_allowed("POST") unless env["REQUEST_METHOD"] == "POST"
        return extension_not_connected_response unless extension_connected?

        # Security check
        security_result = check_security(env, :console)
        return security_error_response(security_result) unless security_result[:success]

        execute_browser_command(env, "getConsoleLogs")
      end

      def handle_wait_command(env)
        return method_not_allowed("POST") unless env["REQUEST_METHOD"] == "POST"

        body = read_request_body(env)
        params = JSON.parse(body)
        
        duration = params["duration"] || 1000
        sleep(duration / 1000.0) # Convert milliseconds to seconds

        [200, { "Content-Type" => "application/json" }, [{ success: true, result: "Waited #{duration}ms" }.to_json]]
      rescue JSON::ParserError => e
        logger.error("Invalid JSON in wait command: #{e.message}")
        [400, { "Content-Type" => "application/json" }, [{ error: "Invalid JSON" }.to_json]]
      end

      # Execute a browser command through the extension
      def execute_browser_command(env, action)
        body = read_request_body(env)
        params = JSON.parse(body)
        
        command_id = SecureRandom.uuid
        command = {
          id: command_id,
          action: action,
          params: params,
          timestamp: Time.now.to_f
        }

        logger.debug("Executing browser command: #{action} with params: #{params}")
        
        # Log browser automation command execution for security audit
        user_context = extract_user_context_from_env(env)
        @security_logger.info("Browser command executed", context: {
          command_id: command_id,
          action: action,
          user_id: user_context[:user_id],
          user_role: user_context[:user_role],
          ip_address: env["REMOTE_ADDR"],
          params: sanitize_params_for_logging(params),
          timestamp: Time.now.iso8601
        })
        
        @command_queue.enqueue_command(command)
        
        # Wait for result with timeout
        result = @command_queue.wait_for_result(command_id, timeout: 30)
        
        # Log command completion
        if result[:success]
          @security_logger.info("Browser command completed", context: {
            command_id: command_id,
            action: action,
            user_id: user_context[:user_id],
            success: true,
            execution_time_ms: ((Time.now.to_f - command[:timestamp]) * 1000).round(2)
          })
          [200, { "Content-Type" => "application/json" }, [result.to_json]]
        else
          @security_logger.warn("Browser command failed", context: {
            command_id: command_id,
            action: action,
            user_id: user_context[:user_id],
            success: false,
            error: result[:error],
            execution_time_ms: ((Time.now.to_f - command[:timestamp]) * 1000).round(2)
          })
          [500, { "Content-Type" => "application/json" }, [result.to_json]]
        end
      rescue JSON::ParserError => e
        logger.error("Invalid JSON in browser command: #{e.message}")
        @security_logger.error("Browser command JSON parsing failed", context: {
          action: action,
          error: e.message,
          ip_address: env["REMOTE_ADDR"],
          user_agent: env["HTTP_USER_AGENT"]
        })
        [400, { "Content-Type" => "application/json" }, [{ error: "Invalid JSON" }.to_json]]
      rescue CommandQueue::TimeoutError
        logger.error("Browser command timed out: #{action}")
        @security_logger.error("Browser command timeout", context: {
          command_id: command_id,
          action: action,
          user_id: user_context[:user_id],
          timeout_seconds: 30
        })
        [408, { "Content-Type" => "application/json" }, [{ error: "Command timed out" }.to_json]]
      end

      # Helper methods
      def read_request_body(env)
        input = env["rack.input"]
        input.rewind
        input.read
      end

      def method_not_allowed(allowed_method)
        [405, { "Content-Type" => "text/plain", "Allow" => allowed_method }, ["Method Not Allowed"]]
      end

      def extension_not_connected_response
        [503, { "Content-Type" => "application/json" }, [{ error: "Chrome extension not connected" }.to_json]]
      end

      def security_error_response(security_result)
        status_code = case security_result[:error_code]
                      when "AUTHENTICATION_REQUIRED"
                        401
                      when "AUTHORIZATION_FAILED"
                        403
                      else
                        401
                      end

        [status_code, { "Content-Type" => "application/json" }, [{ error: security_result[:error] }.to_json]]
      end

      # Extract user context from environment for logging
      def extract_user_context_from_env(env)
        return { user_id: nil, user_role: nil } unless @security_middleware&.security_enabled?

        request = @security_middleware.normalize_request(env)
        result = @security_middleware.process_request(request)
        
        if result[:success] && result[:session_context]
          user = result[:session_context].user
          {
            user_id: user&.[](:id),
            user_role: user&.[](:role)
          }
        else
          { user_id: nil, user_role: nil }
        end
      rescue StandardError
        { user_id: nil, user_role: nil }
      end

      # Sanitize parameters for security logging (remove sensitive data)
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
          if value.is_a?(String) && value.length > 1000
            sanitized[key] = "#{value[0...1000]}...[TRUNCATED]"
          end
        end

        sanitized
      end
    end
  end
end