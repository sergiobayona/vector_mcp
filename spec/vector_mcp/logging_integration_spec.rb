# frozen_string_literal: true

require "spec_helper"
require "tempfile"
require "json"

RSpec.describe "VectorMCP Logging Integration" do
  let(:temp_log_file) { Tempfile.new("vectormcp_test_log") }

  before do
    # Reset logging system for each test
    VectorMCP.instance_variable_set(:@logging_core, nil)
  end

  after do
    temp_log_file.close
    temp_log_file.unlink
  end

  describe "end-to-end logging scenarios" do
    context "with server lifecycle and authentication" do
      it "logs server operations with proper context and structure" do
        # Setup structured logging with file output
        VectorMCP.setup_logging(level: "DEBUG")

        # Add file output
        core = VectorMCP.instance_variable_get(:@logging_core)
        file_output = VectorMCP::Logging::Outputs::File.new(
          path: temp_log_file.path,
          format: "json",
          rotation: "size" # Disable daily rotation for testing
        )
        core.add_output(file_output)

        # Use component loggers throughout the flow
        server_logger = VectorMCP.logger_for("server")
        security_logger = VectorMCP.logger_for("security")
        transport_logger = VectorMCP.logger_for("transport")

        # Log server startup
        server_logger.info("Server starting", context: {
                             name: "TestServer",
                             version: "1.0.0",
                             tools_count: 1
                           })

        # Simulate authentication flow
        security_logger.security("Authentication attempt", context: {
                                   session_id: "test-session",
                                   api_key: "test-key"
                                 })

        security_logger.security("Authentication successful", context: {
                                   session_id: "test-session",
                                   user_id: "user_123",
                                   role: "user"
                                 })

        # Simulate transport request with context
        transport_logger.with_context(session_id: "test-session", request_id: "req_456") do
          transport_logger.debug("Received request", context: {
                                   method: "tools/call",
                                   tool_name: "test_tool"
                                 })

          # Simulate tool execution with measurement
          result = server_logger.measure("Tool execution", context: { tool: "test_tool" }) do
            sleep(0.01) # Simulate work
            "Tool executed successfully"
          end

          transport_logger.info("Request completed", context: {
                                  result_size: result.length,
                                  success: true
                                })
        end

        server_logger.info("Server shutting down")

        # Flush and read log file
        core.shutdown
        log_content = File.read(temp_log_file.path)
        log_lines = log_content.strip.split("\n").map { |line| JSON.parse(line) }

        # Verify log structure and content
        expect(log_lines).not_to be_empty

        # Check server startup log
        startup_log = log_lines.find { |log| log["message"] == "Server starting" }
        expect(startup_log).not_to be_nil
        expect(startup_log["level"]).to eq("INFO")
        expect(startup_log["component"]).to eq("server")
        expect(startup_log["context"]["name"]).to eq("TestServer")

        # Check security logs
        auth_attempt_log = log_lines.find { |log| log["message"] == "Authentication attempt" }
        expect(auth_attempt_log).not_to be_nil
        expect(auth_attempt_log["level"]).to eq("SECURITY")
        expect(auth_attempt_log["component"]).to eq("security")

        # Check context propagation in transport logs
        request_log = log_lines.find { |log| log["message"] == "Received request" }
        expect(request_log).not_to be_nil
        expect(request_log["component"]).to eq("transport")
        expect(request_log["context"]["session_id"]).to eq("test-session")
        expect(request_log["context"]["request_id"]).to eq("req_456")

        # Check performance measurement
        measurement_log = log_lines.find { |log| log["message"] == "Tool execution completed" }
        expect(measurement_log).not_to be_nil
        expect(measurement_log["context"]["duration_ms"]).to be > 0
        expect(measurement_log["context"]["success"]).to be true

        # Verify all logs have required structure
        log_lines.each do |log|
          expect(log).to have_key("timestamp")
          expect(log).to have_key("level")
          expect(log).to have_key("component")
          expect(log).to have_key("message")
        end
      end
    end

    context "with multiple output formats" do
      xit "logs to both console and file with different formats" do
        # Capture stderr for console output
        original_stderr = $stderr
        stderr_output = StringIO.new
        $stderr = stderr_output

        begin
          # Setup logging to both console (text) and file (JSON)
          VectorMCP.setup_logging(
            level: "INFO",
            format: "text", # Console format
            output: "console"
          )

          # Add file output with JSON format
          core = VectorMCP.instance_variable_get(:@logging_core)
          file_output = VectorMCP::Logging::Outputs::File.new(
            path: temp_log_file.path,
            format: "json"
          )
          core.add_output(file_output)

          # Generate some logs
          logger = VectorMCP.logger_for("integration_test")
          logger.info("Test message", context: { key: "value", number: 42 })
          logger.warn("Warning message", context: { alert: true })
          logger.error("Error message", context: { error_code: 500 })

          # Close outputs to flush
          core.shutdown

          # Check console output (text format)
          console_output = stderr_output.string
          expect(console_output).to include("INFO")
          expect(console_output).to include("integration_test")
          expect(console_output).to include("Test message")
          expect(console_output).to include("key=value")
          expect(console_output).to include("number=42")
          expect(console_output).to include("WARN")
          expect(console_output).to include("ERROR")

          # Check file output (JSON format)
          file_content = File.read(temp_log_file.path)
          file_lines = file_content.strip.split("\n").map { |line| JSON.parse(line) }

          expect(file_lines.size).to eq(3)

          info_log = file_lines.find { |log| log["level"] == "INFO" }
          expect(info_log["message"]).to eq("Test message")
          expect(info_log["context"]["key"]).to eq("value")
          expect(info_log["context"]["number"]).to eq(42)

          warn_log = file_lines.find { |log| log["level"] == "WARN" }
          expect(warn_log["message"]).to eq("Warning message")
          expect(warn_log["context"]["alert"]).to be true

          error_log = file_lines.find { |log| log["level"] == "ERROR" }
          expect(error_log["message"]).to eq("Error message")
          expect(error_log["context"]["error_code"]).to eq(500)
        ensure
          $stderr = original_stderr
        end
      end
    end

    context "with component-level filtering" do
      it "respects different log levels for different components" do
        # Setup configuration first
        config = VectorMCP::Logging::Configuration.new(
          level: "WARN",
          format: "json",
          components: {
            "security" => "DEBUG",
            "transport" => "ERROR",
            "server" => "INFO"
          }
        )
        VectorMCP.setup_logging(config)

        # Add file output
        core = VectorMCP.instance_variable_get(:@logging_core)
        file_output = VectorMCP::Logging::Outputs::File.new(
          path: temp_log_file.path,
          format: "json",
          rotation: "size" # Disable daily rotation for testing
        )
        core.add_output(file_output)

        # Create loggers for different components
        security_logger = VectorMCP.logger_for("security")
        transport_logger = VectorMCP.logger_for("transport")
        server_logger = VectorMCP.logger_for("server")
        other_logger = VectorMCP.logger_for("other_component")

        # Log at different levels
        security_logger.debug("Security debug message")    # Should appear (DEBUG >= DEBUG)
        security_logger.info("Security info message")      # Should appear (INFO >= DEBUG)

        transport_logger.warn("Transport warn message")     # Should NOT appear (WARN < ERROR)
        transport_logger.error("Transport error message")   # Should appear (ERROR >= ERROR)

        server_logger.debug("Server debug message")         # Should NOT appear (DEBUG < INFO)
        server_logger.info("Server info message")           # Should appear (INFO >= INFO)

        other_logger.debug("Other debug message")           # Should NOT appear (DEBUG < WARN)
        other_logger.warn("Other warn message")             # Should appear (WARN >= WARN)
        other_logger.error("Other error message")           # Should appear (ERROR >= WARN)

        # Shutdown to flush
        VectorMCP.instance_variable_get(:@logging_core).shutdown

        # Parse log file
        log_content = File.read(temp_log_file.path)
        log_lines = log_content.strip.split("\n").map { |line| JSON.parse(line) }

        messages = log_lines.map { |log| log["message"] }

        # Check which messages appeared
        expect(messages).to include("Security debug message")
        expect(messages).to include("Security info message")
        expect(messages).not_to include("Transport warn message")
        expect(messages).to include("Transport error message")
        expect(messages).not_to include("Server debug message")
        expect(messages).to include("Server info message")
        expect(messages).not_to include("Other debug message")
        expect(messages).to include("Other warn message")
        expect(messages).to include("Other error message")

        expect(log_lines.size).to eq(6)
      end
    end

    context "with error handling and recovery" do
      it "handles logging errors gracefully and continues operation" do
        VectorMCP.setup_logging(level: "DEBUG")

        # Add file output
        core = VectorMCP.instance_variable_get(:@logging_core)
        file_output = VectorMCP::Logging::Outputs::File.new(
          path: temp_log_file.path,
          format: "json",
          rotation: "size" # Disable daily rotation for testing
        )
        core.add_output(file_output)

        logger = VectorMCP.logger_for("error_test")

        # Test with problematic context that causes JSON serialization issues
        circular_ref = {}
        circular_ref[:self] = circular_ref

        problematic_object_class = Class.new do
          def to_s
            raise "Cannot convert to string"
          end

          def inspect
            raise "Cannot inspect"
          end
        end

        # These should not crash the application
        logger.info("Normal message", context: { normal: "data" })
        logger.warn("Message with circular reference", context: { circular: circular_ref })
        logger.error("Message with problematic object", context: {
                       problematic: problematic_object_class.new,
                       normal: "still works"
                     })
        logger.info("Recovery message", context: { recovered: true })

        # Shutdown to flush
        VectorMCP.instance_variable_get(:@logging_core).shutdown

        # Parse what we can from the log file
        log_content = File.read(temp_log_file.path)
        log_lines = log_content.strip.split("\n").map do |line|
          JSON.parse(line)
        rescue JSON::ParserError
          nil
        end.compact

        # Should have at least the normal messages
        messages = log_lines.map { |log| log["message"] }
        expect(messages).to include("Normal message")
        expect(messages).to include("Recovery message")

        # Check that error handling worked
        error_logs = log_lines.select { |log| log["message"]&.include?("JSON serialization failed") }
        expect(error_logs).not_to be_empty
      end
    end

    context "with high-throughput concurrent logging" do
      xit "handles concurrent logging from multiple threads safely" do
        VectorMCP.setup_logging(level: "INFO")

        # Add file output
        core = VectorMCP.instance_variable_get(:@logging_core)
        file_output = VectorMCP::Logging::Outputs::File.new(
          path: temp_log_file.path,
          format: "json",
          rotation: "size" # Disable daily rotation for testing
        )
        core.add_output(file_output)

        # Create multiple loggers
        loggers = (1..5).map { |i| VectorMCP.logger_for("thread_#{i}") }

        # Launch concurrent threads
        threads = []
        messages_per_thread = 50

        loggers.each_with_index do |logger, index|
          threads << Thread.new do
            messages_per_thread.times do |i|
              logger.info("Message #{i} from thread #{index}", context: {
                            thread_id: index,
                            message_num: i,
                            timestamp: Time.now.to_f
                          })

              # Occasionally log at different levels
              logger.warn("Warning #{i} from thread #{index}") if i % 10 == 0

              logger.error("Error #{i} from thread #{index}") if i % 25 == 0
            end
          end
        end

        # Wait for all threads to complete
        threads.each(&:join)

        # Shutdown to flush
        VectorMCP.instance_variable_get(:@logging_core).shutdown

        # Analyze the results
        log_content = File.read(temp_log_file.path)
        log_lines = log_content.strip.split("\n").map { |line| JSON.parse(line) }

        # Should have messages from all threads
        total_expected = (loggers.size * messages_per_thread) + # INFO messages
                         (loggers.size * (messages_per_thread / 10).ceil) + # WARN messages
                         (loggers.size * (messages_per_thread / 25).ceil)   # ERROR messages

        expect(log_lines.size).to eq(total_expected)

        # Verify thread safety - each thread's messages should be complete
        loggers.each_with_index do |_, thread_index|
          thread_messages = log_lines.select do |log|
            log["component"] == "thread_#{thread_index}" &&
              log["message"].start_with?("Message")
          end

          expect(thread_messages.size).to eq(messages_per_thread)

          # Check message sequence
          message_nums = thread_messages.map { |log| log["context"]["message_num"] }.sort
          expect(message_nums).to eq((0...messages_per_thread).to_a)
        end

        # Verify no log corruption (all messages should be valid JSON)
        expect(log_lines).to all(be_a(Hash))
        expect(log_lines).to all(have_key("timestamp"))
        expect(log_lines).to all(have_key("level"))
        expect(log_lines).to all(have_key("component"))
        expect(log_lines).to all(have_key("message"))
      end
    end

    context "with legacy compatibility during migration" do
      xit "allows gradual migration from legacy to new logging" do
        # Start with legacy logging
        legacy_logger = VectorMCP.logger

        # Capture stderr for legacy logs
        original_stderr = $stderr
        stderr_output = StringIO.new
        $stderr = stderr_output

        begin
          # Use legacy logger (this should go to stderr in old format)
          legacy_logger.info("Legacy log message 1")
          legacy_logger.warn("Legacy warning")

          # Setup new logging system
          VectorMCP.setup_logging(level: "DEBUG")

          # Add file output for new system
          core = VectorMCP.instance_variable_get(:@logging_core)
          file_output = VectorMCP::Logging::Outputs::File.new(
            path: temp_log_file.path,
            format: "json"
          )
          core.add_output(file_output)

          # Legacy logger should now use new system but still work
          legacy_logger.info("Hybrid log message")
          legacy_logger.error("Hybrid error message")

          # Use new component loggers alongside legacy
          new_logger = VectorMCP.logger_for("new_component")
          new_logger.info("New system message", context: { migration: true })

          # Legacy logger should still respond to same interface
          expect(legacy_logger).to respond_to(:info)
          expect(legacy_logger).to respond_to(:debug)
          expect(legacy_logger).to respond_to(:level)
          expect(legacy_logger).to respond_to(:level=)
          expect(legacy_logger.progname).to eq("VectorMCP")

          # Level changes should work
          old_level = legacy_logger.level
          legacy_logger.level = VectorMCP::Logging::LEVELS[:DEBUG]
          legacy_logger.debug("Debug message after level change")
          legacy_logger.level = old_level

          # Shutdown new system
          VectorMCP.instance_variable_get(:@logging_core).shutdown

          # Check stderr for legacy messages (before new system was setup)
          stderr_output.string
          # NOTE: After new system setup, legacy logger uses new system
          # So we might not see the old-style messages in stderr anymore

          # Check file for new system messages
          log_content = File.read(temp_log_file.path)
          log_lines = log_content.strip.split("\n").map { |line| JSON.parse(line) }

          messages = log_lines.map { |log| log["message"] }
          expect(messages).to include("Hybrid log message")
          expect(messages).to include("Hybrid error message")
          expect(messages).to include("New system message")
          expect(messages).to include("Debug message after level change")

          # Check that new system logs have proper structure
          new_system_log = log_lines.find { |log| log["message"] == "New system message" }
          expect(new_system_log["component"]).to eq("new_component")
          expect(new_system_log["context"]["migration"]).to be true

          legacy_system_log = log_lines.find { |log| log["message"] == "Hybrid log message" }
          expect(legacy_system_log["component"]).to eq("legacy")
        ensure
          $stderr = original_stderr
        end
      end
    end
  end

  describe "configuration flexibility" do
    it "supports runtime configuration changes" do
      VectorMCP.setup_logging(level: "WARN", format: "text")

      logger = VectorMCP.logger_for("config_test")

      # Initially, debug should not be logged
      expect(logger.debug?).to be false

      # Change configuration at runtime
      VectorMCP.configure_logging do
        level "DEBUG"
        component "config_test", level: "TRACE"
      end

      # Now debug should be enabled
      expect(logger.debug?).to be true
      expect(logger.trace?).to be true

      # Component-specific level should override global
      other_logger = VectorMCP.logger_for("other")
      expect(other_logger.debug?).to be true
      expect(other_logger.trace?).to be false # Global level is DEBUG, not TRACE
    end

    it "supports environment-based configuration" do
      # Set environment variables
      ENV["VECTORMCP_LOG_LEVEL"] = "WARN"
      ENV["VECTORMCP_LOG_FORMAT"] = "json"
      begin
        # Load configuration from environment
        config = VectorMCP::Logging::Configuration.from_env
        VectorMCP.setup_logging(config)

        # Add file output since env doesn't set it up automatically
        core = VectorMCP.instance_variable_get(:@logging_core)
        file_output = VectorMCP::Logging::Outputs::File.new(
          path: temp_log_file.path,
          format: "json",
          rotation: "size" # Disable daily rotation for testing
        )
        core.add_output(file_output)

        logger = VectorMCP.logger_for("env_test")
        logger.warn("Environment test message", context: { env_configured: true })

        # Shutdown to flush
        VectorMCP.instance_variable_get(:@logging_core).shutdown

        # Verify configuration was applied
        expect(core.configuration.config[:level]).to eq("WARN")
        expect(core.configuration.config[:format]).to eq("json")

        # Check that file was written
        log_content = File.read(temp_log_file.path)
        expect(log_content).to include("Environment test message")

        parsed = JSON.parse(log_content.strip)
        expect(parsed["context"]["env_configured"]).to be true
      ensure
        ENV.delete("VECTORMCP_LOG_LEVEL")
        ENV.delete("VECTORMCP_LOG_FORMAT")
      end
    end
  end
end
