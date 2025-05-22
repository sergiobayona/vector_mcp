# frozen_string_literal: true

require "spec_helper"

RSpec.describe VectorMCP::Session do
  let(:server_info) { { name: "TestServer", version: "1.0.0" } }
  let(:server_capabilities) { { tools: { listChanged: true }, resources: { subscribe: true } } }
  let(:protocol_version) { "2024-11-05" }
  let(:server) do
    instance_double("VectorMCP::Server", logger: instance_double("Logger", info: nil, warn: nil, error: nil), server_info: server_info,
                                         server_capabilities: server_capabilities, protocol_version: protocol_version)
  end

  subject(:session) do
    described_class.new(server)
  end

  describe "#initialize" do
    it "sets the correct attributes" do
      expect(session.server).to eq(server)
      expect(session.initialized?).to be false
      expect(session.client_info).to be_nil
      expect(session.client_capabilities).to be_nil
      expect(session.id).to be_a(String)
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
      expect(session.client_capabilities).to eq({ tools: { "listChanged" => true } })
    end

    it "handles missing capabilities in client params" do
      client_params.delete("capabilities")
      result = session.initialize!(client_params)

      expect(result).to include(
        protocolVersion: protocol_version,
        capabilities: server_capabilities,
        serverInfo: server_info
      )
      expect(session.client_capabilities).to be_nil
    end

    context "when protocol version mismatch" do
      let(:different_version) { "2024-11-04" }
      let(:client_params) { { "protocolVersion" => different_version } }

      it "still initializes successfully" do
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
