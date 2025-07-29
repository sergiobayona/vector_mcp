# frozen_string_literal: true

require "async"
require "async/http"

RSpec.describe "Async Transport Integration", type: :integration do
  include HttpStreamIntegrationHelpers

  let(:server_name) { "async-test-server" }
  let(:port) { find_available_port }
  let(:base_url) { "http://localhost:#{port}" }
  let(:server) { create_test_server(name: server_name) }

  context "when using Falcon server with async operations" do
    it "handles concurrent requests asynchronously", :async do
      transport, server_thread = start_test_server(server, port)

      begin
        # Initialize multiple sessions concurrently
        sessions = []
        concurrent_count = 5

        Async do |task|
          concurrent_count.times do |i|
            task.async do
              session_id = "async-session-#{i}"
              sessions << session_id

              # Initialize session
              initialize_mcp_session(base_url, session_id, client_info: {
                name: "async-client-#{i}",
                version: "1.0.0"
              })

              # Make tool calls
              result = call_tool(base_url, session_id, "echo", { message: "Hello from async #{i}" })
              expect(result).to include("Echo: Hello from async #{i}")
            end
          end
        end

        expect(sessions.size).to eq(concurrent_count)
      ensure
        stop_test_server(transport, server_thread)
      end
    end

    it "processes HTTP requests with async/await pattern", :async do
      transport, server_thread = start_test_server(server, port)

      begin
        session_id = "async-pattern-session"

        Async do
          # Initialize session
          initialize_mcp_session(base_url, session_id)

          # Perform sequential async operations
          echo_result = call_tool(base_url, session_id, "echo", { message: "First async call" })
          expect(echo_result).to include("Echo: First async call")

          math_result = call_tool(base_url, session_id, "math_add", { a: 5, b: 3 })
          expect(math_result).to eq(8)

          # Test resource reading
          resource_result = read_resource(base_url, session_id, "test://resource")
          expect(resource_result["result"]["contents"]).to be_present
        end
      ensure
        stop_test_server(transport, server_thread)
      end
    end
  end

  context "when testing async HTTP client usage" do
    it "makes HTTP requests using Async::HTTP", :async do
      transport, server_thread = start_test_server(server, port)

      begin
        Async do
          internet = Async::HTTP::Internet.new

          # Test health check endpoint
          response = internet.get("#{base_url}/")
          expect(response.status).to eq(200)
          body = response.read
          expect(body).to include("VectorMCP")

        ensure
          internet&.close
        end
      ensure
        stop_test_server(transport, server_thread)
      end
    end
  end
end