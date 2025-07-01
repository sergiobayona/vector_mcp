# frozen_string_literal: true

require "spec_helper"
require "tempfile"
require "stringio"

RSpec.describe VectorMCP::Logger do
  let(:original_env) { ENV.to_h }

  # Helper to capture log output
  def capture_log_output
    output = StringIO.new

    # Create a logger that writes to our StringIO
    original_create_ruby_logger = VectorMCP::Logger.instance_method(:create_ruby_logger)

    VectorMCP::Logger.class_eval do
      define_method(:create_ruby_logger) do
        logger = Logger.new(output)
        logger.level = determine_level
        logger.formatter = method(:format_log_entry)
        logger
      end
    end

    yield if block_given?

    # Restore original method
    VectorMCP::Logger.class_eval do
      define_method(:create_ruby_logger, original_create_ruby_logger)
    end

    output
  end

  before do
    # Clean environment for each test
    %w[VECTORMCP_LOG_LEVEL VECTORMCP_LOG_FORMAT VECTORMCP_LOG_OUTPUT VECTORMCP_LOG_FILE].each do |var|
      ENV.delete(var)
    end
  end

  after do
    # Restore original environment
    ENV.clear
    ENV.update(original_env)
  end

  describe "#initialize" do
    it "sets component name from string" do
      logger = described_class.new("test_component")
      expect(logger.component).to eq("test_component")
    end

    it "converts symbol component to string" do
      logger = described_class.new(:test_component)
      expect(logger.component).to eq("test_component")
    end

    it "defaults to 'vectormcp' when no component provided" do
      logger = described_class.new
      expect(logger.component).to eq("vectormcp")
    end

    it "creates ruby logger instance" do
      logger = described_class.new("test")
      expect(logger.ruby_logger).to be_a(Logger)
    end

    it "sets format from environment variable" do
      ENV["VECTORMCP_LOG_FORMAT"] = "json"
      logger = described_class.new("test")
      expect(logger.instance_variable_get(:@format)).to eq("json")
    end

    it "defaults to text format" do
      logger = described_class.new("test")
      expect(logger.instance_variable_get(:@format)).to eq("text")
    end

    it "converts format to lowercase" do
      ENV["VECTORMCP_LOG_FORMAT"] = "JSON"
      logger = described_class.new("test")
      expect(logger.instance_variable_get(:@format)).to eq("json")
    end
  end

  describe ".for" do
    it "creates new logger instance" do
      logger = described_class.for("test_component")
      expect(logger).to be_a(described_class)
      expect(logger.component).to eq("test_component")
    end
  end

  describe "log level methods" do
    before do
      ENV["VECTORMCP_LOG_LEVEL"] = "DEBUG"
    end

    describe "#debug" do
      it "logs debug message" do
        output = capture_log_output do
          logger = described_class.new("test")
          logger.debug("test message")
        end
        expect(output.string).to include("[DEBUG]")
        expect(output.string).to include("[test] test message")
      end

      it "accepts context hash" do
        output = capture_log_output do
          logger = described_class.new("test")
          logger.debug("test message", key: "value")
        end
        expect(output.string).to include("key=value")
      end

      it "accepts block for lazy evaluation" do
        output = capture_log_output do
          logger = described_class.new("test")
          logger.debug { "lazy message" }
        end
        expect(output.string).to include("lazy message")
      end

      it "prefers message over block when both provided" do
        output = capture_log_output do
          logger = described_class.new("test")
          logger.debug("direct message") { "block message" }
        end
        expect(output.string).to include("direct message")
        expect(output.string).not_to include("block message")
      end
    end

    describe "#info" do
      it "logs info message" do
        output = capture_log_output do
          logger = described_class.new("test")
          logger.info("test message")
        end
        expect(output.string).to include("[INFO]")
        expect(output.string).to include("[test] test message")
      end

      it "accepts context and block" do
        output = capture_log_output do
          logger = described_class.new("test")
          logger.info("message", key: "value") { "block" }
        end
        expect(output.string).to include("message")
        expect(output.string).to include("key=value")
      end
    end

    describe "#warn" do
      it "logs warning message" do
        output = capture_log_output do
          logger = described_class.new("test")
          logger.warn("test warning")
        end
        expect(output.string).to include("[WARN]")
        expect(output.string).to include("[test] test warning")
      end
    end

    describe "#error" do
      it "logs error message" do
        output = capture_log_output do
          logger = described_class.new("test")
          logger.error("test error")
        end
        expect(output.string).to include("[ERROR]")
        expect(output.string).to include("[test] test error")
      end
    end

    describe "#fatal" do
      it "logs fatal message" do
        output = capture_log_output do
          logger = described_class.new("test")
          logger.fatal("test fatal")
        end
        expect(output.string).to include("[FATAL]")
        expect(output.string).to include("[test] test fatal")
      end
    end
  end

  describe "#security" do
    it "logs security event as error with prefix" do
      output = capture_log_output do
        logger = described_class.new("security")
        logger.security("auth failed", user_id: "123")
      end
      expect(output.string).to include("[ERROR]")
      expect(output.string).to include("[SECURITY] auth failed")
      expect(output.string).to include("user_id=123")
      expect(output.string).to include("security_event=true")
    end
  end

  describe "#measure" do
    it "measures execution time and logs success" do
      output = capture_log_output do
        logger = described_class.new("perf")
        result = logger.measure("test operation") { "operation result" }
        expect(result).to eq("operation result")
      end

      expect(output.string).to include("test operation completed")
      expect(output.string).to include("duration_ms=")
      expect(output.string).to include("success=true")
    end

    it "includes additional context" do
      output = capture_log_output do
        logger = described_class.new("perf")
        logger.measure("test operation", user_id: "123") { "result" }
      end
      expect(output.string).to include("user_id=123")
    end

    it "logs error when block raises exception" do
      output = capture_log_output do
        logger = described_class.new("perf")
        expect do
          logger.measure("failing operation") { raise StandardError, "test error" }
        end.to raise_error(StandardError, "test error")
      end

      expect(output.string).to include("failing operation failed")
      expect(output.string).to include("success=false")
      expect(output.string).to include("error=StandardError")
      expect(output.string).to include("error_message=test error")
    end

    it "measures duration even when exception occurs" do
      output = capture_log_output do
        logger = described_class.new("perf")
        expect do
          logger.measure("slow failing operation") do
            sleep(0.01)
            raise StandardError, "test error"
          end
        end.to raise_error(StandardError)
      end

      duration_match = output.string.match(/duration_ms=(\d+\.?\d*)/)
      expect(duration_match).not_to be_nil
      expect(duration_match[1].to_f).to be >= 10.0
    end
  end

  describe "environment variable configuration" do
    describe "log level" do
      it "respects VECTORMCP_LOG_LEVEL=DEBUG" do
        ENV["VECTORMCP_LOG_LEVEL"] = "DEBUG"
        logger = described_class.new("test")
        expect(logger.ruby_logger.level).to eq(Logger::DEBUG)
      end

      it "respects VECTORMCP_LOG_LEVEL=INFO" do
        ENV["VECTORMCP_LOG_LEVEL"] = "INFO"
        logger = described_class.new("test")
        expect(logger.ruby_logger.level).to eq(Logger::INFO)
      end

      it "respects VECTORMCP_LOG_LEVEL=ERROR" do
        ENV["VECTORMCP_LOG_LEVEL"] = "ERROR"
        logger = described_class.new("test")
        expect(logger.ruby_logger.level).to eq(Logger::ERROR)
      end

      it "handles case insensitive levels" do
        ENV["VECTORMCP_LOG_LEVEL"] = "debug"
        logger = described_class.new("test")
        expect(logger.ruby_logger.level).to eq(Logger::DEBUG)
      end

      it "defaults to INFO for unknown levels" do
        ENV["VECTORMCP_LOG_LEVEL"] = "UNKNOWN"
        logger = described_class.new("test")
        expect(logger.ruby_logger.level).to eq(Logger::INFO)
      end

      it "defaults to INFO when not set" do
        logger = described_class.new("test")
        expect(logger.ruby_logger.level).to eq(Logger::INFO)
      end

      it "supports TRACE level as DEBUG" do
        ENV["VECTORMCP_LOG_LEVEL"] = "TRACE"
        logger = described_class.new("test")
        expect(logger.ruby_logger.level).to eq(Logger::DEBUG)
      end
    end

    describe "log output" do
      it "defaults to stderr" do
        logger = described_class.new("test")
        expect(logger.ruby_logger.instance_variable_get(:@logdev).dev).to eq($stderr)
      end

      it "uses stdout when configured" do
        ENV["VECTORMCP_LOG_OUTPUT"] = "stdout"
        logger = described_class.new("test")
        expect(logger.ruby_logger.instance_variable_get(:@logdev).dev).to eq($stdout)
      end

      it "handles case insensitive output setting" do
        ENV["VECTORMCP_LOG_OUTPUT"] = "STDOUT"
        logger = described_class.new("test")
        expect(logger.ruby_logger.instance_variable_get(:@logdev).dev).to eq($stdout)
      end
    end

    describe "file output" do
      it "writes to file when configured" do
        temp_file = Tempfile.new("test_log")

        begin
          ENV["VECTORMCP_LOG_OUTPUT"] = "file"
          ENV["VECTORMCP_LOG_FILE"] = temp_file.path

          logger = described_class.new("test")
          logger.info("test message")

          # Close the logger to flush the file
          logger.ruby_logger.close

          content = File.read(temp_file.path)
          expect(content).to include("[test] test message")
        ensure
          temp_file.close
          temp_file.unlink
        end
      end

      it "defaults to vectormcp.log when file path not specified" do
        ENV["VECTORMCP_LOG_OUTPUT"] = "file"

        # Mock File.open to avoid creating actual file
        allow(File).to receive(:open).with("./vectormcp.log", "a").and_return(StringIO.new)

        described_class.new("test")

        expect(File).to have_received(:open).with("./vectormcp.log", "a")
      end
    end
  end

  describe "formatting" do
    describe "text format" do
      before do
        ENV["VECTORMCP_LOG_FORMAT"] = "text"
      end

      it "formats message with component name" do
        output = capture_log_output do
          logger = described_class.new("test")
          logger.info("test message")
        end
        expect(output.string).to match(/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} \[INFO\] \[test\] test message/)
      end

      it "includes context in parentheses" do
        output = capture_log_output do
          logger = described_class.new("test")
          logger.info("message", key1: "value1", key2: "value2")
        end
        expect(output.string).to include("[test] message (key1=value1 key2=value2)")
      end

      it "omits context parentheses when no context" do
        output = capture_log_output do
          logger = described_class.new("test")
          logger.info("simple message")
        end
        expect(output.string).to include("[test] simple message")
        expect(output.string).not_to include("()")
      end
    end

    describe "json format" do
      before do
        ENV["VECTORMCP_LOG_FORMAT"] = "json"
      end

      it "formats as valid JSON" do
        output = capture_log_output do
          logger = described_class.new("test")
          logger.info("test message", key: "value")
        end

        lines = output.string.strip.split("\n")
        json_line = lines.last

        parsed = JSON.parse(json_line)
        expect(parsed["level"]).to eq("INFO")
        expect(parsed["component"]).to eq("test")
        expect(parsed["message"]).to eq("test message")
        expect(parsed["key"]).to eq("value")
        expect(parsed["timestamp"]).to match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}/)
        expect(parsed["thread_id"]).to be_a(Integer)
      end

      it "includes context in JSON" do
        output = capture_log_output do
          logger = described_class.new("test")
          logger.info("message", user_id: 123, action: "login")
        end

        lines = output.string.strip.split("\n")
        parsed = JSON.parse(lines.last)

        expect(parsed["user_id"]).to eq(123)
        expect(parsed["action"]).to eq("login")
      end

      it "omits context when empty" do
        output = capture_log_output do
          logger = described_class.new("test")
          logger.info("simple message")
        end

        lines = output.string.strip.split("\n")
        parsed = JSON.parse(lines.last)

        expect(parsed.keys).to contain_exactly("timestamp", "level", "component", "message", "thread_id")
      end
    end
  end

  describe "log level filtering" do
    context "when level is ERROR" do
      before { ENV["VECTORMCP_LOG_LEVEL"] = "ERROR" }

      it "logs error and fatal messages" do
        output = capture_log_output do
          logger = described_class.new("test")
          logger.debug("debug message")
          logger.info("info message")
          logger.warn("warn message")
          logger.error("error message")
          logger.fatal("fatal message")
        end

        expect(output.string).not_to include("debug message")
        expect(output.string).not_to include("info message")
        expect(output.string).not_to include("warn message")
        expect(output.string).to include("error message")
        expect(output.string).to include("fatal message")
      end
    end

    context "when level is WARN" do
      before { ENV["VECTORMCP_LOG_LEVEL"] = "WARN" }

      it "logs warn, error and fatal messages" do
        output = capture_log_output do
          logger = described_class.new("test")
          logger.debug("debug message")
          logger.info("info message")
          logger.warn("warn message")
          logger.error("error message")
        end

        expect(output.string).not_to include("debug message")
        expect(output.string).not_to include("info message")
        expect(output.string).to include("warn message")
        expect(output.string).to include("error message")
      end
    end
  end

  describe "edge cases and error conditions" do
    it "handles nil message gracefully" do
      output = capture_log_output do
        logger = described_class.new("test")
        logger.info(nil)
      end
      expect(output.string).to include("[test]")
    end

    it "handles empty string message" do
      output = capture_log_output do
        logger = described_class.new("test")
        logger.info("")
      end
      expect(output.string).to include("[test]")
    end

    it "handles complex context values" do
      output = capture_log_output do
        logger = described_class.new("test")
        logger.info("message", array: [1, 2, 3], hash: { nested: "value" })
      end
      expect(output.string).to include("array=[1, 2, 3]")
      # expect(output.string).to include('hash={"nested"=>"value"}').or include("hash={nested: \"value\"}")
    end

    it "handles special characters in component name" do
      logger = described_class.new("test-component_123")
      expect(logger.component).to eq("test-component_123")
    end

    it "handles thread safety" do
      output = capture_log_output do
        logger = described_class.new("test")

        threads = 10.times.map do |i|
          Thread.new do
            logger.info("message #{i}", thread_num: i)
          end
        end

        threads.each(&:join)
      end

      # All messages should be logged
      (0...10).each do |i|
        expect(output.string).to include("message #{i}")
      end
    end
  end

  describe "LEVELS constant" do
    it "maps all expected level names" do
      expect(described_class::LEVELS).to include(
        "TRACE" => Logger::DEBUG,
        "DEBUG" => Logger::DEBUG,
        "INFO" => Logger::INFO,
        "WARN" => Logger::WARN,
        "ERROR" => Logger::ERROR,
        "FATAL" => Logger::FATAL
      )
    end

    it "is frozen" do
      expect(described_class::LEVELS).to be_frozen
    end
  end
end
