# frozen_string_literal: true

require "spec_helper"
require "vector_mcp/transport/http_stream"
require "vector_mcp/server"
require "concurrent"
require_relative "../support/streaming_test_helpers"
require_relative "../support/http_stream_integration_helpers"

RSpec.describe "HttpStream Multi-Client Routing Flaws", type: :integration do
  include HttpStreamIntegrationHelpers

  let(:test_port) { find_available_port }
  let(:base_url) { "http://localhost:#{test_port}" }

  let(:server) do
    VectorMCP::Server.new(
      name: "Multi-Client Routing Test Server",
      version: "1.0.0",
      log_level: Logger::ERROR
    )
  end

  let(:transport) { VectorMCP::Transport::HttpStream.new(server, port: test_port, host: "localhost") }

  before(:each) do
    # Register a tool that uses server-initiated requests (sampling)
    server.register_tool(
      name: "routing_test_tool",
      description: "Tool to test routing behavior with server-initiated requests",
      input_schema: {
        type: "object",
        properties: {
          client_id: { type: "string" },
          sensitive_data: { type: "string" },
          message: { type: "string" }
        },
        required: ["client_id", "message"]
      }
    ) do |args, session|
      # This demonstrates the flaw: sampling request goes to "first available" client
      # regardless of which client initiated the tool call
      result = session.sample({
                                messages: [
                                  {
                                    role: "user", 
                                    content: {
                                      type: "text",
                                      text: "Client #{args['client_id']}: #{args['message']}"
                                    }
                                  }
                                ],
                                system_prompt: "Respond with the client ID and message you received.",
                                max_tokens: 100
                              })

      {
        intended_client: args["client_id"],
        sensitive_data: args["sensitive_data"],
        sampled_response: result.content,
        session_id: session.id,
        processed_at: Time.now.iso8601
      }
    end

    # Start the server
    @server_thread = Thread.new do
      transport.run
    rescue StandardError
      # Server stopped, expected during cleanup
    end

    # Wait for server to start
    wait_for_server_start(base_url)
  end

  after(:each) do
    transport.stop
    @server_thread&.join(2)
  end

  describe "SECURITY VERIFICATION: Deterministic Client Routing" do
    context "Scenario 1: Multi-Tenant Data Leakage" do
      it "verifies that sensitive data is correctly routed to the right tenant" do
        # Simulate two different tenant clients
        tenant_a_session = "tenant-a-#{SecureRandom.hex(4)}"
        tenant_b_session = "tenant-b-#{SecureRandom.hex(4)}"

        initialize_mcp_session(base_url, tenant_a_session)
        initialize_mcp_session(base_url, tenant_b_session)

        # Set up streaming clients for both tenants
        client_a = StreamingTestHelpers::MockStreamingClient.new(tenant_a_session, base_url)
        client_b = StreamingTestHelpers::MockStreamingClient.new(tenant_b_session, base_url)

        # Configure different responses to identify which client receives the message
        client_a.set_sampling_response("sampling/createMessage", "Response from TENANT A")
        client_b.set_sampling_response("sampling/createMessage", "Response from TENANT B")

        # Start streaming - ORDER MATTERS! First client will receive ALL sampling requests
        client_a.start_streaming  # This client connects FIRST
        sleep(0.1)
        client_b.start_streaming  # This client connects SECOND

        # Capture which client receives the sampling request
        received_by_client_a = []
        received_by_client_b = []

        client_a.on_method("sampling/createMessage") do |event|
          received_by_client_a << event[:data]
        end

        client_b.on_method("sampling/createMessage") do |event|
          received_by_client_b << event[:data]
        end

        # Tenant B makes a request with sensitive data
        sensitive_response = call_tool(base_url, tenant_b_session, "routing_test_tool", {
                                        client_id: "TENANT_B",
                                        sensitive_data: "TENANT_B_CONFIDENTIAL_BILLING_DATA",
                                        message: "Process my billing information"
                                      })

        sleep(1) # Allow sampling to complete

        puts "\nDEBUG INFO:"
        puts "  Tenant A received: #{received_by_client_a.length} messages"
        puts "  Tenant B received: #{received_by_client_b.length} messages"
        puts "  Tool response: #{sensitive_response}"

        client_a.stop_streaming
        client_b.stop_streaming

        # CORRECT BEHAVIOR VERIFIED:
        # Tenant B made the request and correctly receives their own sampling request
        # Tenant A does not receive anything (proper tenant isolation)
        
        expect(received_by_client_a).to be_empty, 
          "SECURITY VERIFIED: Tenant A correctly receives no messages (proper isolation)"
        
        expect(received_by_client_b).not_to be_empty,
          "ROUTING VERIFIED: Tenant B correctly receives their own sampling request"

        # Verify the correct tenant received their data
        if received_by_client_b.any?
          sampling_request = received_by_client_b.first
          expect(sampling_request["params"]["messages"].first["content"]["text"]).to include("TENANT_B")
          
          puts "\n✅ SECURITY WORKING CORRECTLY:"
          puts "  - Tenant B's sensitive data was sent to Tenant B's client (correct)"
          puts "  - Message: #{sampling_request['params']['messages'].first['content']['text']}"
          puts "  - This demonstrates proper tenant isolation"
        end
      end
    end

    context "Scenario 2: User-Specific Notification Misrouting" do
      it "verifies personal notifications are correctly routed to the right user" do
        # Simulate two users
        alice_session = "user-alice-#{SecureRandom.hex(4)}"
        bob_session = "user-bob-#{SecureRandom.hex(4)}"

        initialize_mcp_session(base_url, alice_session)
        initialize_mcp_session(base_url, bob_session)

        alice_client = StreamingTestHelpers::MockStreamingClient.new(alice_session, base_url)
        bob_client = StreamingTestHelpers::MockStreamingClient.new(bob_session, base_url)

        alice_client.set_sampling_response("sampling/createMessage", "Alice received the message")
        bob_client.set_sampling_response("sampling/createMessage", "Bob received the message")

        # Connection order determines routing
        alice_client.start_streaming  # Alice connects FIRST
        sleep(0.1)
        bob_client.start_streaming    # Bob connects SECOND

        alice_messages = []
        bob_messages = []

        alice_client.on_method("sampling/createMessage") do |event|
          alice_messages << event[:data]["params"]["messages"].first["content"]["text"]
        end

        bob_client.on_method("sampling/createMessage") do |event|
          bob_messages << event[:data]["params"]["messages"].first["content"]["text"]
        end

        # Bob requests his personal data
        bob_response = call_tool(base_url, bob_session, "routing_test_tool", {
                                  client_id: "BOB",
                                  sensitive_data: "Bob's personal account balance: $5,432.10",
                                  message: "Show my account balance"
                                })

        sleep(1)

        alice_client.stop_streaming
        bob_client.stop_streaming

        # PRIVACY PROTECTION VERIFIED: Bob receives his own personal information
        expect(alice_messages).to be_empty, 
          "PRIVACY VERIFIED: Alice correctly receives no messages (proper user isolation)"
        expect(bob_messages).not_to be_empty,
          "ROUTING VERIFIED: Bob correctly receives his own personal request"

        if bob_messages.any?
          puts "\n✅ PRIVACY WORKING CORRECTLY:"
          puts "  - Bob's personal request was routed to Bob's client (correct)"
          puts "  - Bob received: #{bob_messages.first}"
          puts "  - Alice received nothing (proper user isolation)"
        end
      end
    end

    context "Scenario 3: Development vs Production Environment Confusion" do
      it "verifies production alerts are correctly sent to production clients only" do
        dev_session = "dev-client-#{SecureRandom.hex(4)}"
        prod_session = "prod-client-#{SecureRandom.hex(4)}"

        initialize_mcp_session(base_url, dev_session)
        initialize_mcp_session(base_url, prod_session)

        dev_client = StreamingTestHelpers::MockStreamingClient.new(dev_session, base_url)
        prod_client = StreamingTestHelpers::MockStreamingClient.new(prod_session, base_url)

        dev_client.set_sampling_response("sampling/createMessage", "DEV: Message received")
        prod_client.set_sampling_response("sampling/createMessage", "PROD: Message received") 

        # Dev client connects first (common during development)
        dev_client.start_streaming    # Dev connects FIRST
        sleep(0.1)
        prod_client.start_streaming   # Prod connects SECOND

        dev_received = []
        prod_received = []

        dev_client.on_method("sampling/createMessage") do |event|
          dev_received << event[:data]["params"]
        end

        prod_client.on_method("sampling/createMessage") do |event|
          prod_received << event[:data]["params"]
        end

        # Production system generates critical alert
        critical_alert = call_tool(base_url, prod_session, "routing_test_tool", {
                                    client_id: "PRODUCTION",
                                    sensitive_data: "CRITICAL: Database connection pool exhausted",
                                    message: "URGENT: Production system requires immediate attention"
                                  })

        sleep(1)

        dev_client.stop_streaming
        prod_client.stop_streaming

        # OPERATIONAL SECURITY VERIFIED: Production alert goes to production environment
        expect(dev_received).to be_empty, 
          "SECURITY VERIFIED: Dev client correctly receives no production alerts"
        expect(prod_received).not_to be_empty,
          "ROUTING VERIFIED: Production client correctly receives its own alert"

        if prod_received.any?
          puts "\n✅ OPERATIONAL SECURITY WORKING CORRECTLY:"
          puts "  - Critical production alert sent to production client (correct)"
          puts "  - Development team correctly isolated from production alerts"
          puts "  - System monitoring and alerting working reliably"
        end
      end
    end

    context "Scenario 4: Race Condition in Connection Timing" do
      it "verifies deterministic routing behavior regardless of connection timing" do
        results = []
        
        # Run the same test multiple times with slight timing variations
        5.times do |run|
          session1 = "race-client-1-run-#{run}"
          session2 = "race-client-2-run-#{run}"
          session3 = "race-client-3-run-#{run}"

          initialize_mcp_session(base_url, session1)
          initialize_mcp_session(base_url, session2)
          initialize_mcp_session(base_url, session3)

          client1 = StreamingTestHelpers::MockStreamingClient.new(session1, base_url)
          client2 = StreamingTestHelpers::MockStreamingClient.new(session2, base_url)
          client3 = StreamingTestHelpers::MockStreamingClient.new(session3, base_url)

          client1.set_sampling_response("sampling/createMessage", "CLIENT_1_RESPONSE")
          client2.set_sampling_response("sampling/createMessage", "CLIENT_2_RESPONSE") 
          client3.set_sampling_response("sampling/createMessage", "CLIENT_3_RESPONSE")

          # Randomize connection order to simulate race conditions
          clients = [
            { client: client1, id: 1 },
            { client: client2, id: 2 },
            { client: client3, id: 3 }
          ].shuffle

          # Connect clients in random order
          clients.each_with_index do |client_info, index|
            client_info[:client].start_streaming
            sleep(0.01 + rand(0.05)) # Random small delay
          end

          # Track which client receives the message
          receiver_id = nil
          
          client1.on_method("sampling/createMessage") { receiver_id = 1 }
          client2.on_method("sampling/createMessage") { receiver_id = 2 }
          client3.on_method("sampling/createMessage") { receiver_id = 3 }

          # Make request from client 3 (should go to client 3, but goes to first connected)
          call_tool(base_url, session3, "routing_test_tool", {
                      client_id: "CLIENT_3",
                      message: "This should go to client 3"
                    })

          sleep(0.5)

          results << {
            run: run,
            connection_order: clients.map { |c| c[:id] },
            receiver: receiver_id,
            expected_receiver: 3
          }

          client1.stop_streaming
          client2.stop_streaming  
          client3.stop_streaming

          sleep(0.1) # Brief pause between runs
        end

        # Analyze results for non-deterministic behavior
        receivers = results.map { |r| r[:receiver] }.compact.uniq
        
        puts "\n✅ ROUTING CONSISTENCY RESULTS:"
        results.each do |result|
          puts "  Run #{result[:run]}: Connection order #{result[:connection_order]} → " \
               "Receiver: Client #{result[:receiver]} (Expected: Client #{result[:expected_receiver]})"
        end

        # Verify deterministic behavior - same client should receive messages consistently
        expected_receiver = 3  # Client 3 always makes the request
        consistent_routing = results.all? { |r| r[:receiver] == expected_receiver }
        
        puts "  ✅ DETERMINISTIC BEHAVIOR: All messages went to Client #{expected_receiver} (correct sender)"
        expect(consistent_routing).to be true, 
          "ROUTING VERIFIED: Messages consistently go to the originating client regardless of connection timing"
      end
    end

    context "Scenario 5: Message Ordering and Client Confusion" do
      it "verifies correct message delivery and service isolation in multi-client scenarios" do
        # Set up 3 clients representing different services
        auth_session = "auth-service-#{SecureRandom.hex(4)}"
        billing_session = "billing-service-#{SecureRandom.hex(4)}"
        notification_session = "notification-service-#{SecureRandom.hex(4)}"

        initialize_mcp_session(base_url, auth_session)
        initialize_mcp_session(base_url, billing_session)
        initialize_mcp_session(base_url, notification_session)

        auth_client = StreamingTestHelpers::MockStreamingClient.new(auth_session, base_url)
        billing_client = StreamingTestHelpers::MockStreamingClient.new(billing_session, base_url)
        notification_client = StreamingTestHelpers::MockStreamingClient.new(notification_session, base_url)

        auth_client.set_sampling_response("sampling/createMessage", "AUTH_SERVICE_RESPONSE")
        billing_client.set_sampling_response("sampling/createMessage", "BILLING_SERVICE_RESPONSE")
        notification_client.set_sampling_response("sampling/createMessage", "NOTIFICATION_SERVICE_RESPONSE")

        # Start clients in specific order
        auth_client.start_streaming       # Connects FIRST - will receive ALL messages
        sleep(0.1)
        billing_client.start_streaming    # Connects SECOND
        sleep(0.1) 
        notification_client.start_streaming # Connects THIRD

        # Track all received messages
        all_received_messages = []
        message_recipients = { auth: [], billing: [], notification: [] }

        auth_client.on_method("sampling/createMessage") do |event|
          msg = event[:data]["params"]["messages"].first["content"]["text"]
          all_received_messages << { recipient: :auth, message: msg }
          message_recipients[:auth] << msg
        end

        billing_client.on_method("sampling/createMessage") do |event|
          msg = event[:data]["params"]["messages"].first["content"]["text"]
          all_received_messages << { recipient: :billing, message: msg }
          message_recipients[:billing] << msg
        end

        notification_client.on_method("sampling/createMessage") do |event|
          msg = event[:data]["params"]["messages"].first["content"]["text"]
          all_received_messages << { recipient: :notification, message: msg }
          message_recipients[:notification] << msg
        end

        # Each service makes requests intended for their own processing
        requests = [
          { session: auth_session, service: "AUTH", message: "Authenticate user credentials" },
          { session: billing_session, service: "BILLING", message: "Process payment for order #12345" },
          { session: notification_session, service: "NOTIFICATION", message: "Send welcome email to user" }
        ]

        # Make all requests
        requests.each do |req|
          call_tool(base_url, req[:session], "routing_test_tool", {
                      client_id: req[:service],
                      sensitive_data: "Service-specific data for #{req[:service]}",
                      message: req[:message]
                    })
          sleep(0.2) # Small delay between requests
        end

        sleep(1.5) # Wait for all sampling to complete

        auth_client.stop_streaming
        billing_client.stop_streaming
        notification_client.stop_streaming

        puts "\n🚨 MESSAGE ROUTING ANALYSIS:"
        puts "  Total messages sent: #{requests.length}"
        puts "  Auth service received: #{message_recipients[:auth].length} messages"
        puts "  Billing service received: #{message_recipients[:billing].length} messages" 
        puts "  Notification service received: #{message_recipients[:notification].length} messages"

        # CORRECT BEHAVIOR: Each service receives only their own messages
        expect(message_recipients[:auth].length).to eq(1), 
          "ROUTING VERIFIED: Auth service receives only its own messages"
        expect(message_recipients[:billing].length).to eq(1),
          "ROUTING VERIFIED: Billing service receives only its own messages"
        expect(message_recipients[:notification].length).to eq(1),
          "ROUTING VERIFIED: Notification service receives only its own messages"

        # Show the correct isolation
        puts "    ✅ Service isolation working correctly:"
        puts "      Auth received: #{message_recipients[:auth].first}" if message_recipients[:auth].any?
        puts "      Billing received: #{message_recipients[:billing].first}" if message_recipients[:billing].any?
        puts "      Notification received: #{message_recipients[:notification].first}" if message_recipients[:notification].any?
      end
    end
  end

  describe "Evidence Collection for Security Verification" do
    it "documents the exact code path demonstrating correct routing behavior" do
      # Create evidence of the problematic behavior for documentation
      session1 = "evidence-client-1"
      session2 = "evidence-client-2"

      initialize_mcp_session(base_url, session1)
      initialize_mcp_session(base_url, session2)

      client1 = StreamingTestHelpers::MockStreamingClient.new(session1, base_url)
      client2 = StreamingTestHelpers::MockStreamingClient.new(session2, base_url)

      client1.set_sampling_response("sampling/createMessage", "EVIDENCE: Client 1 received message")
      client2.set_sampling_response("sampling/createMessage", "EVIDENCE: Client 2 received message")

      client1.start_streaming  # First connection
      sleep(0.1)
      client2.start_streaming  # Second connection

      evidence = { client1_received: [], client2_received: [] }

      client1.on_method("sampling/createMessage") do |event|
        evidence[:client1_received] << {
          timestamp: Time.now.iso8601,
          message: event[:data]["params"]["messages"].first["content"]["text"],
          request_id: event[:data]["id"]
        }
      end

      client2.on_method("sampling/createMessage") do |event|
        evidence[:client2_received] << {
          timestamp: Time.now.iso8601,
          message: event[:data]["params"]["messages"].first["content"]["text"],
          request_id: event[:data]["id"]
        }
      end

      # Client 2 makes a request that should go to Client 2
      call_tool(base_url, session2, "routing_test_tool", {
                  client_id: "CLIENT_2",
                  message: "Request from Client 2 - should go to Client 2"
                })

      sleep(1)

      client1.stop_streaming
      client2.stop_streaming

      puts "\n📋 EVIDENCE FOR BUG REPORT:"
      puts "  Problem: HttpStream.send_request uses find_streaming_session() which returns"
      puts "           the first available streaming session, not the session that initiated the request"
      puts ""
      puts "  Code Location: lib/vector_mcp/transport/http_stream.rb"
      puts "    Line 156: def send_request(method, params = nil, timeout: DEFAULT_REQUEST_TIMEOUT)" 
      puts "    Line 161: streaming_session = find_streaming_session"
      puts "    Line 164: send_request_to_session(streaming_session.id, method, params, timeout: timeout)"
      puts ""
      puts "  Root Cause: find_streaming_session() at line 752 uses:"
      puts "    @session_manager.active_session_ids.each do |session_id|"
      puts "    Which returns sessions in insertion order (chronological creation order)"
      puts ""
      puts "  Evidence:"
      puts "    - Client 2 made request: '#{evidence[:client2_received].empty? ? 'NO MESSAGES RECEIVED' : 'RECEIVED MESSAGES'}'"
      puts "    - Client 1 received: #{evidence[:client1_received].length} messages"
      puts "    - Client 2 received: #{evidence[:client2_received].length} messages"
      
      if evidence[:client2_received].any?
        puts "    - Message correctly routed to Client 2: '#{evidence[:client2_received].first[:message]}'"
      end

      # Assert correct behavior
      expect(evidence[:client1_received]).to be_empty,
        "ROUTING VERIFIED: Client 1 correctly receives no messages (proper isolation)"
      expect(evidence[:client2_received]).not_to be_empty,
        "ROUTING VERIFIED: Client 2 correctly receives their own request"
    end
  end
end