# frozen_string_literal: true

RSpec.describe MCPRuby do
  it "has a version number" do
    expect(MCPRuby::VERSION).not_to be nil
  end

  describe "logger configuration" do
    it "has a logger instance" do
      expect(MCPRuby.logger).to be_a(Logger)
    end

    it "logger is configured with stderr output" do
      expect(MCPRuby.logger.instance_variable_get(:@logdev).dev).to eq($stderr)
    end

    it "logger has INFO level by default" do
      expect(MCPRuby.logger.level).to eq(Logger::INFO)
    end

    it "logger has correct progname" do
      expect(MCPRuby.logger.progname).to eq("MCPRuby")
    end
  end

  describe ".new_server" do
    let(:server) { MCPRuby.new_server(name: "test_server") }

    it "creates a new server instance" do
      expect(server).to be_a(MCPRuby::Server)
      expect(server.name).to eq("test_server")
    end

    it "accepts options" do
      server = MCPRuby.new_server(name: "test_server", version: "1.0.0", log_level: Logger::DEBUG)
      expect(server).to be_a(MCPRuby::Server)
      expect(server.version).to eq("1.0.0")
      expect(server.logger.level).to eq(Logger::DEBUG)
    end
  end

  describe "module structure" do
    it "has required submodules" do
      expect(MCPRuby.const_defined?(:Server)).to be true
      expect(MCPRuby.const_defined?(:Definitions)).to be true
      expect(MCPRuby.const_defined?(:Session)).to be true
      expect(MCPRuby.const_defined?(:Util)).to be true
      expect(MCPRuby.const_defined?(:Handlers)).to be true
      expect(MCPRuby.const_defined?(:Transport)).to be true
    end

    it "has Core handler" do
      expect(MCPRuby::Handlers.const_defined?(:Core)).to be true
    end

    it "has Stdio transport" do
      expect(MCPRuby::Transport.const_defined?(:Stdio)).to be true
    end
  end
end
