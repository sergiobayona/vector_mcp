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

      def initialize(logger)
        @logger = logger
        @command_queue = CommandQueue.new(logger)
        @extension_connected = false
        @extension_last_ping = nil
      end

      # Check if Chrome extension is connected
      def extension_connected?
        return false unless @extension_connected
        return true unless @extension_last_ping

        # Consider extension disconnected if no ping in last 30 seconds
        Time.now - @extension_last_ping < 30
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

      private

      # Extension ping endpoint - confirms extension is alive
      def handle_extension_ping(env)
        return method_not_allowed("POST") unless env["REQUEST_METHOD"] == "POST"

        @extension_connected = true
        @extension_last_ping = Time.now
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

        execute_browser_command(env, "navigate")
      end

      def handle_click_command(env)
        return method_not_allowed("POST") unless env["REQUEST_METHOD"] == "POST"
        return extension_not_connected_response unless extension_connected?

        execute_browser_command(env, "click")
      end

      def handle_type_command(env)
        return method_not_allowed("POST") unless env["REQUEST_METHOD"] == "POST"
        return extension_not_connected_response unless extension_connected?

        execute_browser_command(env, "type")
      end

      def handle_snapshot_command(env)
        return method_not_allowed("POST") unless env["REQUEST_METHOD"] == "POST"
        return extension_not_connected_response unless extension_connected?

        execute_browser_command(env, "snapshot")
      end

      def handle_screenshot_command(env)
        return method_not_allowed("POST") unless env["REQUEST_METHOD"] == "POST"
        return extension_not_connected_response unless extension_connected?

        execute_browser_command(env, "screenshot")
      end

      def handle_console_command(env)
        return method_not_allowed("POST") unless env["REQUEST_METHOD"] == "POST"
        return extension_not_connected_response unless extension_connected?

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
        
        @command_queue.enqueue_command(command)
        
        # Wait for result with timeout
        result = @command_queue.wait_for_result(command_id, timeout: 30)
        
        if result[:success]
          [200, { "Content-Type" => "application/json" }, [result.to_json]]
        else
          [500, { "Content-Type" => "application/json" }, [result.to_json]]
        end
      rescue JSON::ParserError => e
        logger.error("Invalid JSON in browser command: #{e.message}")
        [400, { "Content-Type" => "application/json" }, [{ error: "Invalid JSON" }.to_json]]
      rescue CommandQueue::TimeoutError
        logger.error("Browser command timed out: #{action}")
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
    end
  end
end