# frozen_string_literal: true

require "concurrent-ruby"

module VectorMCP
  module Browser
    # Manages the command queue between VectorMCP server and Chrome extension
    class CommandQueue
      class TimeoutError < Error; end

      def initialize(logger)
        @logger = logger
        @queue_logger = VectorMCP.logger_for("browser.queue")
        @pending_commands = Concurrent::Array.new
        @completed_commands = Concurrent::Hash.new
        @result_conditions = Concurrent::Hash.new
      end

      # Add a command to the queue for the extension to pick up
      def enqueue_command(command)
        @pending_commands << command
        @logger.debug("Enqueued command: #{command[:id]} (#{command[:action]})")

        # Log command queuing with structured data
        @queue_logger.info("Command queued", context: {
                             command_id: command[:id],
                             action: command[:action],
                             queue_size: @pending_commands.size,
                             timestamp: Time.now.iso8601
                           })
      end

      # Get all pending commands (called by extension)
      def pending_commands
        commands = @pending_commands.to_a
        @pending_commands.clear

        # Log command dispatch to extension
        if commands.any?
          @queue_logger.info("Commands dispatched to extension", context: {
                               command_count: commands.size,
                               command_ids: commands.map { |cmd| cmd[:id] },
                               actions: commands.map { |cmd| cmd[:action] },
                               timestamp: Time.now.iso8601
                             })
        end

        commands
      end

      # Mark a command as completed with result (called by extension)
      def complete_command(command_id, success, result, error = nil)
        completion_data = {
          success: success,
          result: result,
          error: error,
          completed_at: Time.now.to_f
        }

        @completed_commands[command_id] = completion_data
        @logger.debug("Completed command: #{command_id} (success: #{success})")

        # Log command completion with structured data
        @queue_logger.info("Command completed by extension", context: {
                             command_id: command_id,
                             success: success,
                             error: error,
                             result_size: result.is_a?(Hash) ? result.to_json.length : 0,
                             timestamp: Time.now.iso8601
                           })

        # Signal any waiting threads
        condition = @result_conditions[command_id]
        condition&.set
      end

      # Wait for a command result with timeout
      def wait_for_result(command_id, timeout: 30)
        # Check if result is already available
        return @completed_commands.delete(command_id) if @completed_commands.key?(command_id)

        # Create condition variable for this command
        condition = Concurrent::Event.new
        @result_conditions[command_id] = condition

        # Wait for result with timeout
        if condition.wait(timeout)
          result = @completed_commands.delete(command_id)
          @result_conditions.delete(command_id)
          result
        else
          @result_conditions.delete(command_id)
          raise TimeoutError, "Command #{command_id} timed out after #{timeout} seconds"
        end
      end

      # Get queue statistics for debugging
      def stats
        {
          pending_commands: @pending_commands.size,
          completed_commands: @completed_commands.size,
          waiting_for_results: @result_conditions.size
        }
      end
    end
  end
end
