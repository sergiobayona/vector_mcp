# frozen_string_literal: true

require "logger"
require "json"

module VectorMCP
  # Simple, environment-driven logger for VectorMCP
  # Supports JSON and text formats with component-based identification
  class Logger
    LEVELS = {
      "TRACE" => ::Logger::DEBUG,
      "DEBUG" => ::Logger::DEBUG,
      "INFO" => ::Logger::INFO,
      "WARN" => ::Logger::WARN,
      "ERROR" => ::Logger::ERROR,
      "FATAL" => ::Logger::FATAL
    }.freeze

    attr_reader :component, :ruby_logger

    def initialize(component = "vectormcp")
      @component = component.to_s
      @ruby_logger = create_ruby_logger
      @format = ENV.fetch("VECTORMCP_LOG_FORMAT", "text").downcase
    end

    def self.for(component)
      new(component)
    end

    # Log methods with context support and block evaluation
    def debug(message = nil, **context, &block)
      log(:debug, message || block&.call, context)
    end

    def info(message = nil, **context, &block)
      log(:info, message || block&.call, context)
    end

    def warn(message = nil, **context, &block)
      log(:warn, message || block&.call, context)
    end

    def error(message = nil, **context, &block)
      log(:error, message || block&.call, context)
    end

    def fatal(message = nil, **context, &block)
      log(:fatal, message || block&.call, context)
    end

    # Security-specific logging
    def security(message, **context)
      log(:error, "[SECURITY] #{message}", context.merge(security_event: true))
    end

    # Performance measurement
    def measure(description, **context)
      start_time = Time.now
      result = yield
      duration = Time.now - start_time

      info("#{description} completed", **context, duration_ms: (duration * 1000).round(2),
                                                  success: true)

      result
    rescue StandardError => e
      duration = Time.now - start_time
      error("#{description} failed", **context, duration_ms: (duration * 1000).round(2),
                                                success: false,
                                                error: e.class.name,
                                                error_message: e.message)
      raise
    end

    private

    def log(level, message, context)
      return unless @ruby_logger.send("#{level}?")

      if @format == "json"
        log_json(level, message, context)
      else
        log_text(level, message, context)
      end
    end

    def log_json(level, message, context)
      entry = {
        timestamp: Time.now.iso8601(3),
        level: level.to_s.upcase,
        component: @component,
        message: message,
        thread_id: Thread.current.object_id
      }
      entry.merge!(context) unless context.empty?

      @ruby_logger.send(level, entry.to_json)
    end

    def log_text(level, message, context)
      formatted_message = if context.empty?
                            "[#{@component}] #{message}"
                          else
                            context_str = context.map { |k, v| "#{k}=#{v}" }.join(" ")
                            "[#{@component}] #{message} (#{context_str})"
                          end

      @ruby_logger.send(level, formatted_message)
    end

    def create_ruby_logger
      output = determine_output
      logger = ::Logger.new(output)
      logger.level = determine_level
      logger.formatter = method(:format_log_entry)
      logger
    end

    def determine_output
      case ENV.fetch("VECTORMCP_LOG_OUTPUT", "stderr").downcase
      when "stdout"
        $stdout
      when "file"
        file_path = ENV.fetch("VECTORMCP_LOG_FILE", "./vectormcp.log")
        File.open(file_path, "a")
      else
        $stderr
      end
    end

    def determine_level
      level_name = ENV.fetch("VECTORMCP_LOG_LEVEL", "INFO").upcase
      LEVELS.fetch(level_name, ::Logger::INFO)
    end

    def format_log_entry(severity, datetime, _progname, msg)
      if @format == "json"
        # JSON messages are already formatted
        "#{msg}\n"
      else
        # Text format with timestamp
        timestamp = datetime.strftime("%Y-%m-%d %H:%M:%S.%3N")
        "#{timestamp} [#{severity}] #{msg}\n"
      end
    end
  end
end
