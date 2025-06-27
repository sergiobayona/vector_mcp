# frozen_string_literal: true

require "spec_helper"

RSpec.describe VectorMCP do
  it "has a version number" do
    expect(VectorMCP::VERSION).not_to be nil
  end

  describe "logger configuration" do
    it "has a logger instance" do
      expect(VectorMCP.logger).to be_a(VectorMCP::Logger)
    end

    it "logger_for creates component loggers" do
      logger = VectorMCP.logger_for("test")
      expect(logger).to be_a(VectorMCP::Logger)
      expect(logger.component).to eq("test")
    end
  end

  describe ".new" do
    let(:server) { VectorMCP.new(name: "test_server") }

    it "creates a new server instance" do
      expect(server).to be_a(VectorMCP::Server)
      expect(server.name).to eq("test_server")
    end

    it "accepts options" do
      server = VectorMCP.new(name: "test_server", version: "1.0.0")
      expect(server).to be_a(VectorMCP::Server)
      expect(server.version).to eq("1.0.0")
      # NOTE: log level is now configured via environment variables
      expect(server.logger).to respond_to(:info)
    end
  end

  describe "module structure" do
    it "has required submodules" do
      expect(VectorMCP.const_defined?(:Server)).to be true
      expect(VectorMCP.const_defined?(:Definitions)).to be true
      expect(VectorMCP.const_defined?(:Session)).to be true
      expect(VectorMCP.const_defined?(:Util)).to be true
      expect(VectorMCP.const_defined?(:Handlers)).to be true
      expect(VectorMCP.const_defined?(:Transport)).to be true
    end

    it "has Core handler" do
      expect(VectorMCP::Handlers.const_defined?(:Core)).to be true
    end

    it "has Stdio transport" do
      expect(VectorMCP::Transport.const_defined?(:Stdio)).to be true
    end
  end
end
