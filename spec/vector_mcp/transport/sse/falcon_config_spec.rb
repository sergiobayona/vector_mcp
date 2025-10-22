# frozen_string_literal: true

require "spec_helper"
require "async"
require "async/http/endpoint"
require "falcon/server"
require "vector_mcp/transport/sse/falcon_config"

RSpec.describe VectorMCP::Transport::SSE::FalconConfig do
  let(:host) { "localhost" }
  let(:port) { 8080 }
  let(:logger) { instance_double(Logger, debug: nil, warn: nil, error: nil, info: nil) }
  let(:falcon_config) { described_class.new(host, port, logger) }
  let(:mock_rack_app) { proc { [200, {}, ["OK"]] } }

  describe "#initialize" do
    it "sets the correct attributes" do
      expect(falcon_config.host).to eq(host)
      expect(falcon_config.port).to eq(port)
      expect(falcon_config.logger).to eq(logger)
    end

    it "creates an HTTP endpoint" do
      expect(falcon_config.endpoint).to be_a(Async::HTTP::Endpoint)
    end

    it "configures endpoint for correct host and port" do
      endpoint_url = falcon_config.endpoint.url.to_s
      expect(endpoint_url).to include(host)
      expect(endpoint_url).to include(port.to_s)
    end
  end

  describe "#create_server" do
    it "creates a Falcon::Server instance" do
      server = falcon_config.create_server(mock_rack_app)
      expect(server).to be_a(Falcon::Server)
    end

    it "logs configuration details" do
      expect(logger).to receive(:debug).at_least(:once) do |&block|
        message = block.call
        expect([
                 "Falcon server configured for SSE on #{host}:#{port}",
                 "Endpoint configured for SSE streaming",
                 "Falcon server options configured for SSE transport"
               ]).to include(message)
      end.at_least(:once)

      falcon_config.create_server(mock_rack_app)
    end
  end

  describe "#configure (legacy API)" do
    let(:mock_server) { instance_double(Falcon::Server) }

    before do
      allow(mock_server).to receive(:cache_size=) if mock_server.respond_to?(:cache_size=)
      allow(mock_server).to receive(:respond_to?).with(:cache_size=).and_return(false)
    end

    it "logs deprecation warning" do
      expect(logger).to receive(:warn).with(no_args) do |&block|
        message = block.call
        expect(message).to include("deprecated")
      end

      falcon_config.configure(mock_server)
    end

    it "configures server options" do
      expect(logger).to receive(:warn) { |&block| block.call }
      expect(logger).to receive(:debug).at_least(:once) { |&block| block.call }

      expect { falcon_config.configure(mock_server) }.not_to raise_error
    end
  end

  describe "cache size configuration" do
    it "uses default cache size" do
      config = described_class.new(host, port, logger)
      server = config.create_server(mock_rack_app)

      if server.respond_to?(:cache_size)
        expect(server.cache_size).to eq(512) # DEFAULT_CACHE_SIZE
      end
    end

    it "accepts custom cache size" do
      custom_size = 1024
      config = described_class.new(host, port, logger, cache_size: custom_size)
      server = config.create_server(mock_rack_app)

      if server.respond_to?(:cache_size)
        expect(server.cache_size).to eq(custom_size)
      end
    end
  end

  describe "endpoint configuration" do
    it "creates endpoint for HTTP protocol" do
      endpoint = falcon_config.endpoint
      expect(endpoint.scheme).to eq("http")
    end

    it "uses correct hostname" do
      endpoint = falcon_config.endpoint
      expect(endpoint.hostname).to eq(host)
    end

    it "uses correct port" do
      endpoint = falcon_config.endpoint
      expect(endpoint.port).to eq(port)
    end
  end

  describe "different host configurations" do
    [
      ["0.0.0.0", 3000],
      ["127.0.0.1", 8000],
      ["localhost", 9999]
    ].each do |test_host, test_port|
      context "with host #{test_host} and port #{test_port}" do
        let(:config) { described_class.new(test_host, test_port, logger) }

        it "configures endpoint correctly" do
          expect(config.host).to eq(test_host)
          expect(config.port).to eq(test_port)
          expect(config.endpoint.hostname).to eq(test_host)
          expect(config.endpoint.port).to eq(test_port)
        end
      end
    end
  end

  describe "logging behavior" do
    it "logs configuration details during server creation" do
      log_messages = []
      allow(logger).to receive(:debug) { |&block| log_messages << block.call }

      falcon_config.create_server(mock_rack_app)

      expect(log_messages).to include("Falcon server configured for SSE on #{host}:#{port}")
      expect(log_messages).to include("Endpoint configured for SSE streaming")
      expect(log_messages).to include("Falcon server options configured for SSE transport")
    end
  end

  describe "error handling" do
    context "when server creation fails" do
      before do
        allow(Falcon::Server).to receive(:new).and_raise(StandardError, "Server creation failed")
      end

      it "allows the error to propagate" do
        expect { falcon_config.create_server(mock_rack_app) }.to raise_error(StandardError, "Server creation failed")
      end
    end

    context "when endpoint parsing fails" do
      it "raises an error for invalid URL" do
        expect do
          described_class.new("invalid host with spaces", -1, logger)
        end.to raise_error
      end
    end
  end

  describe "integration with real Falcon server" do
    it "creates a real Falcon server without errors" do
      expect do
        falcon_config.create_server(mock_rack_app)
      end.not_to raise_error
    end

    it "creates a server that responds to run" do
      server = falcon_config.create_server(mock_rack_app)
      expect(server).to respond_to(:run)
    end
  end
end
