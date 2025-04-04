require "spec_helper"
require "async"
require "async/http/server"
require "async/http/client"
require "async/http/endpoint"
require "uri"

require_relative "../../../lib/mcp_ruby/server"

RSpec.describe MCPRuby::Transport::SSE do
  let(:app) do
    MCPRuby::Server.new(
      name: "test-server",
      transport: :sse
    )
  end

  let(:endpoint) { Async::HTTP::Endpoint.parse("http://localhost:9293") }

  it "responds with 200 OK and correct SSE headers" do
    Async do
      server_task = Async do
        Falcon::Server.new(app, endpoint).run
      end

      # Give the server a brief moment to spin up
      sleep 0.1

      client = Async::HTTP::Client.new(endpoint)

      response = client.get("/v1/sse")

      expect(response.status).to eq 200

      headers = response.headers

      expect(headers["content-type"]).to include("text/event-stream")
      expect(headers["cache-control"]).to eq("no-cache")
      expect(headers["connection"]).to eq("keep-alive")

      # optionally verify that the body is still open for streaming
      expect(response.body).to be_a(Async::HTTP::Body::Writable)

      client.close
      server_task.stop
    end
  end
end
