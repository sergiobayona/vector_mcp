# frozen_string_literal: true

require "spec_helper"
require "vector_mcp/transport/sse"

RSpec.describe VectorMCP::Transport::SSE, "security fix for shared session state" do
  let(:mock_logger) { instance_double(Logger, info: nil, debug: nil, warn: nil, error: nil, fatal: nil) }
  let(:mock_server) do
    instance_double(
      VectorMCP::Server,
      logger: mock_logger,
      server_info: { name: "TestServer", version: "0.1" },
      server_capabilities: {},
      protocol_version: "2024-11-05"
    )
  end

  describe "default behavior (secure session isolation)" do
    it "enables session manager by default" do
      transport = described_class.new(mock_server)
      expect(transport.session_manager).not_to be_nil
      expect(transport.session_manager).to be_a(VectorMCP::Transport::SseSessionManager)
    end

    it "does not log deprecation warning with default settings" do
      expect(mock_logger).not_to receive(:warn)
      described_class.new(mock_server)
    end
  end

  describe "legacy behavior (deprecated)" do
    it "logs deprecation warning when disabling session manager" do
      expect(mock_logger).to receive(:warn).with(
        /DEPRECATED.*SSE shared session mode is deprecated.*security risks/
      )

      transport = described_class.new(mock_server, disable_session_manager: true)
      expect(transport.session_manager).to be_nil
    end

    it "still works with shared session when explicitly disabled" do
      allow(mock_logger).to receive(:warn) # Allow the deprecation warning

      transport = described_class.new(mock_server, disable_session_manager: true)
      expect(transport.session_manager).to be_nil

      # Should be able to build rack app without error
      expect { transport.build_rack_app }.not_to raise_error
    end
  end

  describe "security implications documentation" do
    it "explains the security risk in the deprecation message" do
      expect(mock_logger).to receive(:warn).with(
        a_string_including("security risks in multi-client scenarios")
      )

      described_class.new(mock_server, disable_session_manager: true)
    end

    it "provides guidance on fixing the issue" do
      expect(mock_logger).to receive(:warn).with(
        a_string_including("Consider removing disable_session_manager: true")
      )

      described_class.new(mock_server, disable_session_manager: true)
    end
  end
end
