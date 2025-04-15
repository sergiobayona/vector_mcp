# frozen_string_literal: true

require "spec_helper"

RSpec.describe VectorMCP::Session do
  let(:server_info) { { name: "TestServer", version: "1.0.0" } }
  let(:server_capabilities) { { tools: { listChanged: true }, resources: { subscribe: true } } }
  let(:protocol_version) { "2024-11-05" }

  subject(:session) do
    described_class.new(
      server_info: server_info,
      server_capabilities: server_capabilities,
      protocol_version: protocol_version
    )
  end

  describe "#initialize" do
    it "sets the correct attributes" do
      expect(session.server_info).to eq(server_info)
      expect(session.server_capabilities).to eq(server_capabilities)
      expect(session.protocol_version).to eq(protocol_version)
      expect(session.client_capabilities).to eq({})
    end

    it "starts in uninitialized state" do
      expect(session.initialized?).to be false
    end
  end

  describe "#initialize!" do
    let(:client_params) do
      {
        "protocolVersion" => protocol_version,
        "capabilities" => { "tools" => { "listChanged" => true } }
      }
    end

    it "initializes the session with client parameters" do
      result = session.initialize!(client_params)

      expect(result).to include(
        protocolVersion: protocol_version,
        capabilities: server_capabilities,
        serverInfo: server_info
      )
      expect(session.initialized?).to be true
      expect(session.client_capabilities).to eq(client_params["capabilities"])
    end

    it "handles missing capabilities in client params" do
      client_params.delete("capabilities")
      result = session.initialize!(client_params)

      expect(result).to include(
        protocolVersion: protocol_version,
        capabilities: server_capabilities,
        serverInfo: server_info
      )
      expect(session.client_capabilities).to eq({})
    end

    context "when protocol version mismatch" do
      let(:different_version) { "2024-11-04" }
      let(:client_params) { { "protocolVersion" => different_version } }

      it "logs a warning but still initializes" do
        expect(VectorMCP.logger).to receive(:warn).with(
          "Client requested protocol version '#{different_version}', server using '#{protocol_version}'"
        )

        session.initialize!(client_params)
        expect(session.initialized?).to be true
      end
    end
  end

  describe "#initialized?" do
    it "returns false before initialization" do
      expect(session.initialized?).to be false
    end

    it "returns true after initialization" do
      session.initialize!({ "protocolVersion" => protocol_version })
      expect(session.initialized?).to be true
    end
  end
end
