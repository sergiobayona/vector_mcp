# frozen_string_literal: true

require "spec_helper"
require "tempfile"
require "json"

RSpec.describe "VectorMCP Core Logging Integration" do
  let(:temp_log_file) { Tempfile.new("vectormcp_test_log") }

  before do
    # Reset logging system for each test
    VectorMCP.instance_variable_set(:@logging_core, nil)
  end

  after do
    temp_log_file.close
    temp_log_file.unlink
  end

  describe "comprehensive logging workflow" do
    it "demonstrates full logging capabilities with structured output" do
      # Setup structured logging with file output
      VectorMCP.setup_logging(level: "DEBUG")

      # Add file output with size-based rotation for consistent behavior
      core = VectorMCP.instance_variable_get(:@logging_core)
      file_output = VectorMCP::Logging::Outputs::File.new(
        path: temp_log_file.path,
        format: "json",
        rotation: "size"
      )
      core.add_output(file_output)

      # Test component loggers with different levels
      server_logger = VectorMCP.logger_for("server")
      security_logger = VectorMCP.logger_for("security")
      transport_logger = VectorMCP.logger_for("transport")

      # Test basic logging with context
      server_logger.info("Server initialized", context: {
                           name: "TestServer",
                           version: "1.0.0",
                           features: %w[authentication logging]
                         })

      # Test security logging (special SECURITY level)
      security_logger.security("Authentication event", context: {
                                 user_id: "user_123",
                                 action: "login",
                                 success: true
                               })

      # Test context propagation with with_context
      transport_logger.with_context(session_id: "sess_456", request_id: "req_789") do
        transport_logger.debug("Processing request", context: {
                                 method: "tools/call",
                                 tool_name: "calculator"
                               })

        # Test performance measurement
        result = server_logger.measure("Tool execution", context: { tool: "calculator" }) do
          sleep(0.005) # Simulate work
          { result: 42 }
        end

        transport_logger.info("Request completed", context: {
                                result: result,
                                success: true
                              })
      end

      # Test different log levels
      server_logger.trace("Trace message")
      server_logger.debug("Debug message")
      server_logger.warn("Warning message")
      server_logger.error("Error message")

      # Test context accumulation
      server_logger.add_context(server_instance: "main")
      server_logger.info("Message with persistent context")
      server_logger.clear_context
      server_logger.info("Message after context clear")

      # Shutdown to flush
      core.shutdown

      # Parse and validate log output
      log_content = File.read(temp_log_file.path)
      expect(log_content).not_to be_empty

      log_lines = log_content.strip.split("\n").map { |line| JSON.parse(line) }
      expect(log_lines.size).to be >= 8 # At least 8 log messages

      # Verify log structure
      log_lines.each do |log|
        expect(log).to have_key("timestamp")
        expect(log).to have_key("level")
        expect(log).to have_key("component")
        expect(log).to have_key("message")
        expect(log["timestamp"]).to match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
      end

      # Test specific log entries
      server_init_log = log_lines.find { |log| log["message"] == "Server initialized" }
      expect(server_init_log).not_to be_nil
      expect(server_init_log["level"]).to eq("INFO")
      expect(server_init_log["component"]).to eq("server")
      expect(server_init_log["context"]["name"]).to eq("TestServer")
      expect(server_init_log["context"]["features"]).to include("authentication", "logging")

      # Test security log
      security_log = log_lines.find { |log| log["message"] == "Authentication event" }
      expect(security_log).not_to be_nil
      expect(security_log["level"]).to eq("SECURITY")
      expect(security_log["component"]).to eq("security")
      expect(security_log["context"]["user_id"]).to eq("user_123")

      # Test context propagation
      request_log = log_lines.find { |log| log["message"] == "Processing request" }
      expect(request_log).not_to be_nil
      expect(request_log["component"]).to eq("transport")
      expect(request_log["context"]["session_id"]).to eq("sess_456")
      expect(request_log["context"]["request_id"]).to eq("req_789")
      expect(request_log["context"]["method"]).to eq("tools/call")

      # Test performance measurement
      measurement_log = log_lines.find { |log| log["message"] == "Tool execution completed" }
      expect(measurement_log).not_to be_nil
      expect(measurement_log["context"]["duration_ms"]).to be > 0
      expect(measurement_log["context"]["success"]).to be true
      expect(measurement_log["context"]["tool"]).to eq("calculator")

      # Test context accumulation
      persistent_context_log = log_lines.find { |log| log["message"] == "Message with persistent context" }
      expect(persistent_context_log).not_to be_nil
      expect(persistent_context_log["context"]["server_instance"]).to eq("main")

      clear_context_log = log_lines.find { |log| log["message"] == "Message after context clear" }
      expect(clear_context_log).not_to be_nil
      # Context might be nil or empty hash after clear
      expect(clear_context_log["context"]).not_to have_key("server_instance") if clear_context_log["context"]

      # Verify timestamp ordering
      timestamps = log_lines.map { |log| Time.parse(log["timestamp"]) }
      expect(timestamps).to eq(timestamps.sort)

      # Test log levels are present
      levels = log_lines.map { |log| log["level"] }.uniq
      expect(levels).to include("DEBUG", "INFO", "WARN", "ERROR", "SECURITY")
    end

    it "supports component-level log filtering" do
      # Setup configuration with different component levels
      config = VectorMCP::Logging::Configuration.new(
        level: "WARN",
        components: {
          "security" => "DEBUG",
          "server" => "INFO",
          "ignored" => "ERROR"
        }
      )
      VectorMCP.setup_logging(config)

      core = VectorMCP.instance_variable_get(:@logging_core)
      file_output = VectorMCP::Logging::Outputs::File.new(
        path: temp_log_file.path,
        format: "json",
        rotation: "size"
      )
      core.add_output(file_output)

      # Create loggers for different components
      security_logger = VectorMCP.logger_for("security")
      server_logger = VectorMCP.logger_for("server")
      ignored_logger = VectorMCP.logger_for("ignored")
      default_logger = VectorMCP.logger_for("default")

      # Log at different levels
      security_logger.debug("Security debug")     # Should appear (DEBUG >= DEBUG)
      security_logger.info("Security info")       # Should appear (INFO >= DEBUG)

      server_logger.debug("Server debug")         # Should NOT appear (DEBUG < INFO)
      server_logger.info("Server info")           # Should appear (INFO >= INFO)

      ignored_logger.warn("Ignored warn")         # Should NOT appear (WARN < ERROR)
      ignored_logger.error("Ignored error")       # Should appear (ERROR >= ERROR)

      default_logger.debug("Default debug")       # Should NOT appear (DEBUG < WARN)
      default_logger.warn("Default warn")         # Should appear (WARN >= WARN)

      core.shutdown

      log_content = File.read(temp_log_file.path)
      log_lines = log_content.strip.split("\n").map { |line| JSON.parse(line) }
      messages = log_lines.map { |log| log["message"] }

      # Verify filtering worked correctly
      expect(messages).to include("Security debug", "Security info")
      expect(messages).not_to include("Server debug")
      expect(messages).to include("Server info")
      expect(messages).not_to include("Ignored warn")
      expect(messages).to include("Ignored error")
      expect(messages).not_to include("Default debug")
      expect(messages).to include("Default warn")

      expect(log_lines.size).to eq(5) # Only 5 messages should pass filtering
    end

    it "handles concurrent logging safely" do
      VectorMCP.setup_logging(level: "INFO")

      core = VectorMCP.instance_variable_get(:@logging_core)
      file_output = VectorMCP::Logging::Outputs::File.new(
        path: temp_log_file.path,
        format: "json",
        rotation: "size"
      )
      core.add_output(file_output)

      # Create multiple loggers for concurrent access
      loggers = (1..3).map { |i| VectorMCP.logger_for("thread_#{i}") }
      messages_per_logger = 10

      # Launch concurrent threads
      threads = []

      loggers.each_with_index do |logger, index|
        threads << Thread.new do
          messages_per_logger.times do |i|
            logger.info("Message #{i} from logger #{index}", context: {
                          logger_index: index,
                          message_num: i
                        })
          end
        end
      end

      # Wait for all threads to complete
      threads.each(&:join)
      core.shutdown

      # Verify results
      log_content = File.read(temp_log_file.path)
      log_lines = log_content.strip.split("\n").map { |line| JSON.parse(line) }

      total_expected = loggers.size * messages_per_logger
      expect(log_lines.size).to eq(total_expected)

      # Verify each logger's messages are complete
      loggers.each_with_index do |_, logger_index|
        logger_messages = log_lines.select do |log|
          log["component"] == "thread_#{logger_index + 1}"
        end

        expect(logger_messages.size).to eq(messages_per_logger)

        # Check message sequence
        message_nums = logger_messages.map { |log| log["context"]["message_num"] }.sort
        expect(message_nums).to eq((0...messages_per_logger).to_a)
      end

      # Verify no log corruption
      log_lines.each do |log|
        expect(log).to be_a(Hash)
        expect(log).to have_key("timestamp")
        expect(log).to have_key("level")
        expect(log).to have_key("component")
        expect(log).to have_key("message")
      end
    end

    it "maintains backward compatibility with legacy logger" do
      # Test legacy logger before and after new system setup
      legacy_logger = VectorMCP.logger

      # Legacy logger should work (though we can't easily test output without complex setup)
      expect(legacy_logger).to respond_to(:info)
      expect(legacy_logger).to respond_to(:debug)
      expect(legacy_logger).to respond_to(:warn)
      expect(legacy_logger).to respond_to(:error)
      expect(legacy_logger).to respond_to(:fatal)
      expect(legacy_logger).to respond_to(:level)
      expect(legacy_logger).to respond_to(:level=)
      expect(legacy_logger.progname).to eq("VectorMCP")

      # Setup new logging system
      VectorMCP.setup_logging(level: "DEBUG")

      # Legacy logger should still work with same interface
      expect(legacy_logger).to respond_to(:info)
      expect(legacy_logger.progname).to eq("VectorMCP")

      # Level changes should work
      old_level = legacy_logger.level
      legacy_logger.level = VectorMCP::Logging::LEVELS[:WARN]
      expect(legacy_logger.level).to eq(VectorMCP::Logging::LEVELS[:WARN])
      legacy_logger.level = old_level

      # New component loggers should work alongside legacy
      new_logger = VectorMCP.logger_for("new_component")
      expect(new_logger).to be_a(VectorMCP::Logging::Component)
      expect(new_logger.name).to eq("new_component")
    end

    it "supports runtime configuration changes" do
      VectorMCP.setup_logging(level: "WARN")

      logger = VectorMCP.logger_for("dynamic_test")

      # Initially, debug should not be enabled
      expect(logger.debug?).to be false
      expect(logger.warn?).to be true

      # Change global configuration
      VectorMCP.configure_logging do
        level "DEBUG"
      end

      # Now debug should be enabled
      expect(logger.debug?).to be true

      # Change component-specific level
      VectorMCP.configure_logging do
        component "dynamic_test", level: "ERROR"
      end

      # Component should now have ERROR level while global remains DEBUG
      expect(logger.error?).to be true
      expect(logger.warn?).to be false
      expect(logger.info?).to be false

      # Other components should still use global level
      other_logger = VectorMCP.logger_for("other")
      expect(other_logger.debug?).to be true
      expect(other_logger.warn?).to be true
    end
  end
end
