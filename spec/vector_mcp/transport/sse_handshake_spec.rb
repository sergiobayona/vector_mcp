# frozen_string_literal: true

require "spec_helper"
require "async"
require "async/http/server"
require "async/http/client"
require "async/http/endpoint"
require "uri"

# Require necessary VectorMCP classes
require_relative "../../../lib/vector_mcp/server"
require_relative "../../../lib/vector_mcp/transport/sse"
require_relative "../../../lib/vector_mcp/session"

RSpec.describe VectorMCP::Transport::SSE, skip: true do
  # Mocks for dependencies
  let(:mock_logger) { instance_double(Logger, info: nil, debug: nil, warn: nil, error: nil, fatal: nil, :<< => nil) }
  let(:mock_server_info) { { name: "TestServer", version: "0.1" } }
  let(:mock_server_capabilities) { {} }
  let(:mock_protocol_version) { "2024-11-05" }
  let(:mock_mcp_server) do
    instance_double(
      VectorMCP::Server,
      logger: mock_logger,
      server_info: mock_server_info,
      server_capabilities: mock_server_capabilities,
      protocol_version: mock_protocol_version
      # No need to mock handle_message for this specific handshake test
    )
  end
  let(:mock_session) { instance_double(VectorMCP::Session) }

  # Instantiate the SSE Transport itself
  let(:sse_transport) { described_class.new(mock_mcp_server) }

  # The Rack app IS the transport instance now
  let(:rack_app) { sse_transport }

  let(:endpoint) { Async::HTTP::Endpoint.parse("http://localhost:9293") }

  it "responds with 200 OK and correct SSE headers" do
    Async do
      # Use the actual rack_app built by the transport
      server_task = Async do
        # Wrap the rack_app with Falcon's default middleware so that Rack responses
        # are converted into Protocol::HTTP::Response objects. Without this,
        # Falcon would receive the raw Rack triplet which triggers a
        # `NoMethodError: undefined method `body' for an instance of Array`.
        server = Falcon::Server.new(Falcon::Server.middleware(rack_app), endpoint)
        server.run
      end

      # Give the server a brief moment to spin up
      sleep 0.1

      client = Async::HTTP::Client.new(endpoint)

      # The default prefix is /mcp, so request /mcp/sse
      response = client.get("/mcp/sse")

      expect(response.status).to eq 200

      headers = response.headers

      expect(headers["content-type"]).to include("text/event-stream")
      expect(headers["cache-control"]).to include("no-cache")

      # optionally verify that the body is still open for streaming
      expect(response.body).to be_a(Protocol::HTTP::Body::Readable)

      client.close
      server_task.stop
    end
  end
end
