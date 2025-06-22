# frozen_string_literal: true

require "spec_helper"

RSpec.describe VectorMCP::Logging do
  describe "module constants" do
    it "defines log levels" do
      expect(VectorMCP::Logging::LEVELS).to include(
        TRACE: 0,
        DEBUG: 1,
        INFO: 2,
        WARN: 3,
        ERROR: 4,
        FATAL: 5,
        SECURITY: 6
      )
    end

    it "provides level name lookup" do
      expect(VectorMCP::Logging.level_name(0)).to eq("TRACE")
      expect(VectorMCP::Logging.level_name(2)).to eq("INFO")
      expect(VectorMCP::Logging.level_name(6)).to eq("SECURITY")
      expect(VectorMCP::Logging.level_name(999)).to eq("UNKNOWN")
    end

    it "provides level value lookup" do
      expect(VectorMCP::Logging.level_value("DEBUG")).to eq(1)
      expect(VectorMCP::Logging.level_value(:INFO)).to eq(2)
      expect(VectorMCP::Logging.level_value("invalid")).to eq(2) # defaults to INFO
    end
  end

  describe "VectorMCP integration" do
    before do
      # Reset logging system for each test
      VectorMCP.instance_variable_set(:@logging_core, nil)
    end

    it "maintains backward compatibility with legacy logger" do
      legacy_logger = VectorMCP.logger
      expect(legacy_logger).to respond_to(:info)
      expect(legacy_logger).to respond_to(:debug)
      expect(legacy_logger).to respond_to(:error)
    end

    it "creates component loggers" do
      logger = VectorMCP.logger_for("test_component")
      expect(logger).to be_a(VectorMCP::Logging::Component)
      expect(logger.name).to eq("test_component")
    end

    it "configures logging system" do
      VectorMCP.configure_logging do
        level "DEBUG"
        component "security", level: "WARN"
      end

      config = VectorMCP.instance_variable_get(:@logging_core).configuration
      expect(config.config[:level]).to eq("DEBUG")
      expect(config.config[:components]["security"]).to eq("WARN")
    end

    it "sets up logging with configuration" do
      config = { level: "WARN", format: "json" }
      core = VectorMCP.setup_logging(config)
      
      expect(core).to be_a(VectorMCP::Logging::Core)
      expect(core.configuration.config[:level]).to eq("WARN")
      expect(core.configuration.config[:format]).to eq("json")
    end
  end

  describe VectorMCP::Logging::Configuration do
    it "initializes with defaults" do
      config = VectorMCP::Logging::Configuration.new
      expect(config.config[:level]).to eq("INFO")
      expect(config.config[:format]).to eq("text")
      expect(config.config[:output]).to eq("console")
    end

    it "loads from environment variables" do
      ENV["VECTORMCP_LOG_LEVEL"] = "DEBUG"
      ENV["VECTORMCP_LOG_FORMAT"] = "json"
      
      config = VectorMCP::Logging::Configuration.from_env
      expect(config.config[:level]).to eq("DEBUG")
      expect(config.config[:format]).to eq("json")
      
      ENV.delete("VECTORMCP_LOG_LEVEL")
      ENV.delete("VECTORMCP_LOG_FORMAT")
    end

    it "validates configuration" do
      expect {
        VectorMCP::Logging::Configuration.new(level: "INVALID")
      }.to raise_error(VectorMCP::Logging::ConfigurationError)
      
      expect {
        VectorMCP::Logging::Configuration.new(format: "invalid")
      }.to raise_error(VectorMCP::Logging::ConfigurationError)
    end
  end

  describe VectorMCP::Logging::Component do
    let(:core) { VectorMCP::Logging::Core.new }
    let(:component) { core.logger_for("test") }

    it "logs at different levels" do
      expect(component).to respond_to(:trace)
      expect(component).to respond_to(:debug)
      expect(component).to respond_to(:info)
      expect(component).to respond_to(:warn)
      expect(component).to respond_to(:error)
      expect(component).to respond_to(:fatal)
      expect(component).to respond_to(:security)
    end

    it "checks level enablement" do
      # Default level is INFO
      expect(component.trace?).to be false
      expect(component.debug?).to be false
      expect(component.info?).to be true
      expect(component.warn?).to be true
      expect(component.error?).to be true
    end

    it "manages context" do
      component.add_context(user_id: "123")
      component.with_context(request_id: "abc") do
        # Context should include both user_id and request_id
        expect(component.instance_variable_get(:@context)).to include(
          user_id: "123",
          request_id: "abc"
        )
      end
      # After block, only user_id should remain
      expect(component.instance_variable_get(:@context)).to eq(user_id: "123")
    end

    it "measures performance" do
      result = component.measure("test operation") do
        sleep(0.01)
        "test result"
      end
      
      expect(result).to eq("test result")
    end
  end

  describe VectorMCP::Logging::Formatters do
    let(:log_entry) do
      VectorMCP::Logging::LogEntry.new(
        timestamp: Time.parse("2025-01-01 12:00:00"),
        level: VectorMCP::Logging::LEVELS[:INFO],
        component: "test",
        message: "Test message",
        context: { key: "value" },
        thread_id: 12345
      )
    end

    describe VectorMCP::Logging::Formatters::Text do
      it "formats text output" do
        formatter = VectorMCP::Logging::Formatters::Text.new
        output = formatter.format(log_entry)
        
        expect(output).to include("INFO")
        expect(output).to include("test")
        expect(output).to include("Test message")
        expect(output).to include("key=value")
        expect(output).to end_with("\n")
      end

      it "supports colorization" do
        formatter = VectorMCP::Logging::Formatters::Text.new(colorize: true)
        output = formatter.format(log_entry)
        
        expect(output).to include("\e[32m") # Green for INFO
        expect(output).to include("\e[0m")  # Reset
      end
    end

    describe VectorMCP::Logging::Formatters::Json do
      it "formats JSON output" do
        formatter = VectorMCP::Logging::Formatters::Json.new
        output = formatter.format(log_entry)
        
        parsed = JSON.parse(output.strip)
        expect(parsed["level"]).to eq("INFO")
        expect(parsed["component"]).to eq("test")
        expect(parsed["message"]).to eq("Test message")
        expect(parsed["context"]["key"]).to eq("value")
      end

      it "handles serialization errors gracefully" do
        # Create a context with a circular reference to force JSON serialization failure
        circular_ref = {}
        circular_ref[:self] = circular_ref
        
        bad_entry = VectorMCP::Logging::LogEntry.new(
          timestamp: Time.now,
          level: VectorMCP::Logging::LEVELS[:INFO],
          component: "test",
          message: "Test message",
          context: { circular: circular_ref },
          thread_id: 12345
        )

        formatter = VectorMCP::Logging::Formatters::Json.new
        output = formatter.format(bad_entry)
        
        parsed = JSON.parse(output.strip)
        expect(parsed["message"]).to include("JSON serialization failed")
        expect(parsed["original_message"]).to eq("Test message")
      end
    end
  end
end