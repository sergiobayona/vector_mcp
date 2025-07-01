#!/usr/bin/env ruby
# frozen_string_literal: true

# Example middleware implementations demonstrating various use cases
# Run with: ruby examples/middleware_examples.rb

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "vector_mcp"

# Example 1: PII Redaction Middleware
# Automatically scrubs sensitive information from inputs and outputs
class PiiRedactionMiddleware < VectorMCP::Middleware::Base
  def initialize(config = {})
    super
    @patterns = config[:patterns] || default_patterns
    @replacement = config[:replacement] || "[REDACTED]"
  end

  def before_tool_call(context)
    logger.debug("Redacting PII from tool call", operation: context.operation_name)

    # In a real implementation, we'd modify the params if they were mutable
    # For now, we'll just log what we would redact
    redact_object(context.params)
  end

  def after_tool_call(context)
    logger.debug("Redacting PII from tool response", operation: context.operation_name)

    # Redact sensitive data from response
    return unless context.result.is_a?(Hash) && context.result[:content]

    context.result = redact_response(context.result)
  end

  private

  def default_patterns
    [
      /\b\d{3}-\d{2}-\d{4}\b/, # SSN
      /\b\d{4}\s?\d{4}\s?\d{4}\s?\d{4}\b/, # Credit Card
      /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b/ # Email
    ]
  end

  def redact_object(obj)
    case obj
    when String
      @patterns.reduce(obj) { |str, pattern| str.gsub(pattern, @replacement) }
    when Hash
      obj.transform_values { |v| redact_object(v) }
    when Array
      obj.map { |v| redact_object(v) }
    else
      obj
    end
  end

  def redact_response(response)
    redacted_response = response.dup
    if redacted_response[:content].is_a?(Array)
      redacted_response[:content] = redacted_response[:content].map do |item|
        if item[:text]
          item.merge(text: redact_object(item[:text]))
        else
          item
        end
      end
    end
    redacted_response
  end
end

# Example 2: Retry Middleware
# Automatically retries failed operations with exponential backoff
class RetryMiddleware < VectorMCP::Middleware::Base
  def initialize(config = {})
    super
    @max_retries = config[:max_retries] || 3
    @base_delay = config[:base_delay] || 1.0
    @retryable_errors = config[:retryable_errors] || [StandardError]
  end

  def on_tool_error(context)
    retry_count = context.metadata[:retry_count] || 0

    if should_retry?(context.error, retry_count)
      logger.info("Retrying tool call", {
                    operation: context.operation_name,
                    attempt: retry_count + 1,
                    error: context.error.class.name
                  })

      # Wait with exponential backoff
      delay = @base_delay * (2**retry_count)
      sleep(delay)

      # Mark for retry
      context.metadata[:retry_count] = retry_count + 1

      # In a real implementation, we'd trigger the retry here
      # For this example, we'll just modify the context
      context.add_metadata(:retried, true)

      # Clear the error to indicate we're handling it
      context.error = nil

      # Set a mock successful result
      context.result = {
        isError: false,
        content: [{ type: "text", text: "Retry successful (simulated)" }]
      }
    else
      logger.error("Max retries exceeded", {
                     operation: context.operation_name,
                     attempts: retry_count + 1
                   })
    end
  end

  private

  def should_retry?(error, retry_count)
    return false if retry_count >= @max_retries

    @retryable_errors.any? { |error_class| error.is_a?(error_class) }
  end
end

# Example 3: Custom Logging Middleware
# Enhanced logging with business metrics and context
class CustomLoggingMiddleware < VectorMCP::Middleware::Base
  def initialize(config = {})
    super
    @include_params = config[:include_params] || false
    @include_results = config[:include_results] || false
  end

  def before_tool_call(context)
    context.add_metadata(:start_time, Time.now)

    log_data = {
      event: "tool_call_started",
      operation: context.operation_name,
      session_id: context.session&.id,
      user_id: context.user&.[](:user_id)
    }

    log_data[:params] = context.params if @include_params

    logger.info("Tool call started", log_data)
  end

  def after_tool_call(context)
    start_time = context.metadata[:start_time]
    duration = start_time ? Time.now - start_time : 0

    log_data = {
      event: "tool_call_completed",
      operation: context.operation_name,
      session_id: context.session&.id,
      user_id: context.user&.[](:user_id),
      duration_ms: (duration * 1000).round(2),
      success: context.success?
    }

    log_data[:result] = context.result if @include_results

    logger.info("Tool call completed", log_data)
  end

  def on_tool_error(context)
    start_time = context.metadata[:start_time]
    duration = start_time ? Time.now - start_time : 0

    logger.error("Tool call failed", {
                   event: "tool_call_failed",
                   operation: context.operation_name,
                   session_id: context.session&.id,
                   user_id: context.user&.[](:user_id),
                   duration_ms: (duration * 1000).round(2),
                   error_class: context.error&.class&.name,
                   error_message: context.error&.message
                 })
  end
end

# Example 4: Rate Limiting Middleware
# Per-user rate limiting for tools
class RateLimitingMiddleware < VectorMCP::Middleware::Base
  def initialize(config = {})
    super
    @limits = config[:limits] || { default: 100 } # requests per minute
    @windows = {}
    @window_size = 60 # seconds
  end

  def before_tool_call(context)
    user_id = context.user&.[](:user_id) || "anonymous"
    tool_name = context.operation_name

    key = "#{user_id}:#{tool_name}"
    limit = @limits[tool_name.to_sym] || @limits[:default]

    if rate_limited?(key, limit)
      logger.warn("Rate limit exceeded", {
                    user_id: user_id,
                    tool: tool_name,
                    limit: limit
                  })

      # Stop execution by setting an error
      context.error = VectorMCP::InvalidParamsError.new(
        "Rate limit exceeded. Try again later."
      )
      skip_remaining_hooks(context)
    else
      increment_counter(key)
    end
  end

  private

  def rate_limited?(key, limit)
    now = Time.now.to_i
    window_start = now - (now % @window_size)

    @windows[key] ||= {}
    @windows[key][window_start] ||= 0

    # Clean old windows
    @windows[key].delete_if { |time, _| time < window_start - @window_size }

    current_count = @windows[key].values.sum
    current_count >= limit
  end

  def increment_counter(key)
    now = Time.now.to_i
    window_start = now - (now % @window_size)

    @windows[key] ||= {}
    @windows[key][window_start] ||= 0
    @windows[key][window_start] += 1
  end
end

# Demo server with middleware
def demo_middleware
  # Create server
  server = VectorMCP.new(name: "MiddlewareDemo", version: "1.0.0")

  # Register a simple tool
  server.register_tool(
    name: "echo",
    description: "Echoes the input with optional error simulation",
    input_schema: {
      type: "object",
      properties: {
        message: { type: "string" },
        simulate_error: { type: "boolean", default: false }
      },
      required: ["message"]
    }
  ) do |args|
    raise StandardError, "Simulated error for testing" if args["simulate_error"]

    "Echo: #{args["message"]}"
  end

  # Register middleware in order of execution (by priority)
  server.use_middleware(CustomLoggingMiddleware, %i[
                          before_tool_call after_tool_call on_tool_error
                        ], priority: 10, conditions: { include_params: true })

  server.use_middleware(RateLimitingMiddleware, :before_tool_call,
                        priority: 20,
                        conditions: { limits: { echo: 5, default: 10 } })

  server.use_middleware(PiiRedactionMiddleware, %i[
                          before_tool_call after_tool_call
                        ], priority: 30)

  server.use_middleware(RetryMiddleware, :on_tool_error,
                        priority: 40,
                        conditions: { max_retries: 2, base_delay: 0.5 })

  puts "Middleware Demo Server"
  puts "Registered middleware: #{server.middleware_stats[:total_hooks]} hooks"
  puts "Hook types: #{server.middleware_stats[:hook_types].join(", ")}"
  puts ""
  puts "Try calling the 'echo' tool with various inputs to see middleware in action!"
  puts "Set 'simulate_error: true' to test retry middleware."

  # For demo purposes, simulate some tool calls instead of running the server
  puts "\n--- Simulating tool calls to demonstrate middleware ---"

  # This would normally happen through the transport layer
  # but we're simulating for demonstration
  puts "\n1. Normal tool call:"
  puts "Input: { message: 'Hello, World!' }"

  puts "\n2. Tool call with PII:"
  puts "Input: { message: 'My email is john@example.com and SSN is 123-45-6789' }"

  puts "\n3. Tool call with error (will trigger retry):"
  puts "Input: { message: 'Test error', simulate_error: true }"

  puts "\nMiddleware hooks would be executed automatically for each call!"
  puts "Check the logs to see middleware in action."
end

# Run the demo if this file is executed directly
demo_middleware if __FILE__ == $PROGRAM_NAME
