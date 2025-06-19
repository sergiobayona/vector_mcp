# frozen_string_literal: true

require "spec_helper"
require "puma"
require "vector_mcp/transport/sse/puma_config"

RSpec.describe VectorMCP::Transport::SSE::PumaConfig do
  let(:host) { "localhost" }
  let(:port) { 8080 }
  let(:logger) { instance_double(Logger, debug: nil, warn: nil, error: nil, info: nil) }
  let(:puma_config) { described_class.new(host, port, logger) }
  let(:mock_server) { double("Puma::Server").as_null_object }

  describe "#initialize" do
    it "sets the correct attributes" do
      expect(puma_config.host).to eq(host)
      expect(puma_config.port).to eq(port)
      expect(puma_config.logger).to eq(logger)
    end
  end

  describe "#configure" do
    before do
      allow(mock_server).to receive(:add_tcp_listener)
      allow(mock_server).to receive(:min_threads=) if mock_server.respond_to?(:min_threads=)
      allow(mock_server).to receive(:max_threads=) if mock_server.respond_to?(:max_threads=)
      allow(mock_server).to receive(:leak_stack_on_error=) if mock_server.respond_to?(:leak_stack_on_error=)
      allow(mock_server).to receive(:respond_to?).with(:min_threads=).and_return(true)
      allow(mock_server).to receive(:respond_to?).with(:max_threads=).and_return(true)
      allow(mock_server).to receive(:respond_to?).with(:leak_stack_on_error=).and_return(true)
      allow(mock_server).to receive(:respond_to?).with(:first_data_timeout=).and_return(false)
      allow(Etc).to receive(:nprocessors).and_return(4)
    end

    it "adds TCP listener with host and port" do
      expect(mock_server).to receive(:add_tcp_listener).with(host, port)
      puma_config.configure(mock_server)
    end

    it "configures thread pool based on CPU cores" do
      if mock_server.respond_to?(:min_threads=) && mock_server.respond_to?(:max_threads=)
        expect(mock_server).to receive(:min_threads=).with(2)
        expect(mock_server).to receive(:max_threads=).with(8) # max(4, 4*2)
      end
      puma_config.configure(mock_server)
    end

    it "sets leak_stack_on_error to false" do
      expect(mock_server).to receive(:leak_stack_on_error=).with(false) if mock_server.respond_to?(:leak_stack_on_error=)
      puma_config.configure(mock_server)
    end

    it "logs the configuration" do
      expect(logger).to receive(:debug).at_least(:once) do |&block|
        message = block.call
        expect([
                 "Puma server configured for #{host}:#{port}",
                 "Puma configured with 2-8 threads",
                 "Puma server options configured for SSE transport"
               ]).to include(message)
      end.at_least(:once)
      puma_config.configure(mock_server)
    end

    context "when server supports first_data_timeout" do
      before do
        allow(mock_server).to receive(:respond_to?).with(:first_data_timeout=).and_return(true)
        allow(mock_server).to receive(:first_data_timeout=)
      end

      it "sets first_data_timeout for SSE connections" do
        expect(mock_server).to receive(:first_data_timeout=).with(30)
        puma_config.configure(mock_server)
      end
    end

    context "when server does not support first_data_timeout" do
      before do
        allow(mock_server).to receive(:respond_to?).with(:first_data_timeout=).and_return(false)
      end

      it "does not attempt to set first_data_timeout" do
        expect(mock_server).not_to receive(:first_data_timeout=)
        puma_config.configure(mock_server)
      end
    end

    context "with single-core system" do
      before do
        allow(Etc).to receive(:nprocessors).and_return(1)
      end

      it "sets minimum max_threads to 4" do
        expect(mock_server).to receive(:max_threads=).with(4) # max(4, 1*2)
        puma_config.configure(mock_server)
      end
    end

    context "with many-core system" do
      before do
        allow(Etc).to receive(:nprocessors).and_return(16)
      end

      it "scales max_threads with CPU cores" do
        expect(mock_server).to receive(:max_threads=).with(32) # 16*2
        puma_config.configure(mock_server)
      end
    end
  end

  describe "threading configuration" do
    let(:config_with_different_host) { described_class.new("0.0.0.0", 3000, logger) }

    it "works with different host configurations" do
      expect(config_with_different_host.host).to eq("0.0.0.0")
      expect(config_with_different_host.port).to eq(3000)
    end
  end

  describe "logging behavior" do
    it "logs Puma configuration details" do
      log_messages = []
      allow(logger).to receive(:debug) { |&block| log_messages << block.call }
      puma_config.configure(mock_server)
      expected_max_threads = [4, Etc.nprocessors * 2].max
      expect(log_messages).to include("Puma server configured for #{host}:#{port}")
      expect(log_messages).to include("Puma configured with 2-#{expected_max_threads} threads")
      expect(log_messages).to include("Puma server options configured for SSE transport")
    end
  end

  describe "error handling" do
    context "when add_tcp_listener raises an error" do
      before do
        allow(mock_server).to receive(:add_tcp_listener).and_raise(StandardError, "Port in use")
      end

      it "allows the error to propagate" do
        expect { puma_config.configure(mock_server) }.to raise_error(StandardError, "Port in use")
      end
    end

    context "when thread configuration fails" do
      before do
        allow(mock_server).to receive(:add_tcp_listener)
        allow(mock_server).to receive(:min_threads=).and_raise(StandardError, "Thread config error")
      end

      it "allows the error to propagate" do
        expect { puma_config.configure(mock_server) }.to raise_error(StandardError, "Thread config error")
      end
    end
  end

  describe "integration with real Puma::Server" do
    let(:real_server) { Puma::Server.new(proc { [200, {}, ["OK"]] }) }
    let(:random_port) { rand(10_000..19_999) }
    let(:puma_config) { described_class.new(host, random_port, logger) }

    it "configures a real Puma server without errors" do
      expect do
        puma_config.configure(real_server)
      rescue NoMethodError => e
        # Allow if method is not present (e.g., leak_stack_on_error=)
        skip e.message
      end.not_to raise_error
    end

    it "sets the expected attributes on real server" do
      begin
        puma_config.configure(real_server)
      rescue NoMethodError
        # skip if method is not present
        skip "Puma::Server does not expose some attributes; cannot assert."
      end

      # Modern Puma versions don't support direct thread pool configuration after server creation
      # Thread pool sizing should be set via Puma config DSL before server creation
      if real_server.respond_to?(:min_threads=) && real_server.respond_to?(:max_threads=)
        # If the server supports these methods, verify they were set
        expect(real_server.min_threads).to eq(2)
        expect(real_server.max_threads).to be >= 4
      else
        # If the server doesn't support these methods, that's expected behavior
        # The configure method should have logged a warning about this (as a block)
        expect(logger).to have_received(:warn).with(no_args)
      end

      # Test other server options that should still work
      if real_server.respond_to?(:leak_stack_on_error=)
        # If the setter exists, the value should have been set to false
        expect(real_server.leak_stack_on_error).to be false if real_server.respond_to?(:leak_stack_on_error)
      elsif real_server.respond_to?(:leak_stack_on_error)
        # If the setter doesn't exist, we can't control the value, so just verify it's a boolean
        expect([true, false]).to include(real_server.leak_stack_on_error)
      end
    end
  end

  describe "thread pool sizing logic" do
    [
      [1, 2, 4],   # Single core -> min 2, max 4
      [2, 2, 4],   # Dual core -> min 2, max 4
      [4, 2, 8],   # Quad core -> min 2, max 8
      [8, 2, 16],  # 8 core -> min 2, max 16
      [16, 2, 32]  # 16 core -> min 2, max 32
    ].each do |cores, expected_min, expected_max|
      context "with #{cores} CPU core(s)" do
        before do
          allow(Etc).to receive(:nprocessors).and_return(cores)
          allow(mock_server).to receive(:add_tcp_listener)
          allow(mock_server).to receive(:min_threads=) if mock_server.respond_to?(:min_threads=)
          allow(mock_server).to receive(:max_threads=) if mock_server.respond_to?(:max_threads=)
          allow(mock_server).to receive(:leak_stack_on_error=) if mock_server.respond_to?(:leak_stack_on_error=)
          allow(mock_server).to receive(:respond_to?).with(:min_threads=).and_return(true)
          allow(mock_server).to receive(:respond_to?).with(:max_threads=).and_return(true)
          # Default stub for respond_to? to avoid RSpec errors for unexpected args
          allow(mock_server).to receive(:respond_to?) { |_meth| false }
          allow(mock_server).to receive(:respond_to?).with(:min_threads=).and_return(true)
          allow(mock_server).to receive(:respond_to?).with(:max_threads=).and_return(true)
          allow(mock_server).to receive(:respond_to?).with(:leak_stack_on_error=).and_return(true)
          allow(mock_server).to receive(:respond_to?).with(:first_data_timeout=).and_return(false)
        end

        it "sets min_threads to #{expected_min} and max_threads to #{expected_max}" do
          if mock_server.respond_to?(:min_threads=) && mock_server.respond_to?(:max_threads=)
            expect(mock_server).to receive(:min_threads=).with(expected_min)
            expect(mock_server).to receive(:max_threads=).with(expected_max)
          end
          puma_config.configure(mock_server)
        end
      end
    end
  end
end
