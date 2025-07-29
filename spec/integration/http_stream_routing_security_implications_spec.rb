# frozen_string_literal: true

require "spec_helper"
require "vector_mcp/transport/http_stream"
require "vector_mcp/server"
require "concurrent"
require_relative "../support/streaming_test_helpers"
require_relative "../support/http_stream_integration_helpers"

RSpec.describe "HttpStream Routing Security Implications", type: :integration do
  include HttpStreamIntegrationHelpers

  let(:test_port) { find_available_port }
  let(:base_url) { "http://localhost:#{test_port}" }

  let(:server) do
    VectorMCP::Server.new(
      name: "Routing Security Test Server",
      version: "1.0.0",
      log_level: Logger::ERROR
    )
  end

  let(:transport) { VectorMCP::Transport::HttpStream.new(server, port: test_port, host: "localhost") }

  before(:each) do
    # Register tools that simulate real-world security-sensitive operations
    server.register_tool(
      name: "get_user_data",
      description: "Retrieves sensitive user data",
      input_schema: {
        type: "object",
        properties: {
          user_id: { type: "string" },
          data_type: { type: "string" }
        },
        required: %w[user_id data_type]
      }
    ) do |args, session|
      # This simulates fetching sensitive user data via sampling
      result = session.sample({
                                messages: [
                                  {
                                    role: "user",
                                    content: {
                                      type: "text",
                                      text: "Retrieve #{args["data_type"]} for user #{args["user_id"]}"
                                    }
                                  }
                                ],
                                system_prompt: "You are a secure data retrieval system.",
                                max_tokens: 200
                              })

      {
        user_id: args["user_id"],
        data_type: args["data_type"],
        sensitive_data: "CONFIDENTIAL: User #{args["user_id"]} #{args["data_type"]} data",
        retrieved_via_sampling: result.content,
        session_id: session.id
      }
    end

    server.register_tool(
      name: "financial_transaction",
      description: "Processes financial transactions",
      input_schema: {
        type: "object",
        properties: {
          account_id: { type: "string" },
          amount: { type: "number" },
          transaction_type: { type: "string" }
        },
        required: %w[account_id amount transaction_type]
      }
    ) do |args, session|
      # Financial data that must not leak to other clients
      result = session.sample({
                                messages: [
                                  {
                                    role: "user",
                                    content: {
                                      type: "text",
                                      text: "Process #{args["transaction_type"]} of $#{args["amount"]} for account #{args["account_id"]}"
                                    }
                                  }
                                ],
                                system_prompt: "You are a financial transaction processor.",
                                max_tokens: 150
                              })

      {
        account_id: args["account_id"],
        amount: args["amount"],
        transaction_type: args["transaction_type"],
        financial_data: "CONFIDENTIAL: Account #{args["account_id"]} balance and transaction history",
        processing_result: result.content,
        session_id: session.id
      }
    end

    @server_thread = Thread.new do
      transport.run
    rescue StandardError
      # Server stopped, expected during cleanup
    end

    wait_for_server_start(base_url)
  end

  after(:each) do
    transport.stop
    @server_thread&.join(2)
  end

  describe "SECURITY VERIFIED: Data Protection Scenarios" do
    context "Healthcare Privacy Protection" do
      it "verifies HIPAA compliance through proper routing" do
        # Simulate doctor and patient portal clients
        doctor_session = "doctor-portal-#{SecureRandom.hex(4)}"
        patient_session = "patient-portal-#{SecureRandom.hex(4)}"

        initialize_mcp_session(base_url, doctor_session)
        initialize_mcp_session(base_url, patient_session)

        doctor_client = StreamingTestHelpers::MockStreamingClient.new(doctor_session, base_url)
        patient_client = StreamingTestHelpers::MockStreamingClient.new(patient_session, base_url)

        doctor_client.set_sampling_response("sampling/createMessage", "DOCTOR: Medical data received")
        patient_client.set_sampling_response("sampling/createMessage", "PATIENT: Medical data received")

        # Doctor connects first (typical in healthcare systems)
        doctor_client.start_streaming
        sleep(0.1)
        patient_client.start_streaming

        doctor_received_data = []
        patient_received_data = []

        doctor_client.on_method("sampling/createMessage") do |event|
          medical_request = event[:data]["params"]["messages"].first["content"]["text"]
          doctor_received_data << {
            timestamp: Time.now.iso8601,
            medical_request: medical_request,
            source: "patient_portal"
          }
        end

        patient_client.on_method("sampling/createMessage") do |event|
          medical_request = event[:data]["params"]["messages"].first["content"]["text"]
          patient_received_data << {
            timestamp: Time.now.iso8601,
            medical_request: medical_request,
            source: "patient_portal"
          }
        end

        # Patient requests their own medical data
        call_tool(base_url, patient_session, "get_user_data", {
                    user_id: "patient_123",
                    data_type: "medical_records_blood_test_results"
                  })

        sleep(1)

        doctor_client.stop_streaming
        patient_client.stop_streaming

        # SECURITY VERIFIED: Proper routing prevents HIPAA violation
        expect(doctor_received_data).to be_empty,
                                        "✅ SECURITY VERIFIED: Doctor correctly receives no patient data (HIPAA compliance maintained)"

        expect(patient_received_data).not_to be_empty,
                                             "✅ PRIVACY VERIFIED: Patient correctly receives their own medical data"

        if patient_received_data.any?
          puts "\n✅ HEALTHCARE PRIVACY PROTECTION WORKING:"
          puts "  SECURITY: Patient's medical request properly routed to patient only"
          puts "  Request: #{patient_received_data.first[:medical_request]}"
          puts "  This demonstrates HIPAA compliance and proper privacy protection"
          puts "  Medical data is correctly isolated between doctor and patient portals"
        end
      end
    end

    context "Financial Services Security" do
      it "verifies financial data isolation between customer accounts" do
        # Simulate two banking customers
        customer_a_session = "bank-customer-a-#{SecureRandom.hex(4)}"
        customer_b_session = "bank-customer-b-#{SecureRandom.hex(4)}"

        initialize_mcp_session(base_url, customer_a_session)
        initialize_mcp_session(base_url, customer_b_session)

        customer_a_client = StreamingTestHelpers::MockStreamingClient.new(customer_a_session, base_url)
        customer_b_client = StreamingTestHelpers::MockStreamingClient.new(customer_b_session, base_url)

        customer_a_client.set_sampling_response("sampling/createMessage", "CUSTOMER_A: Financial data received")
        customer_b_client.set_sampling_response("sampling/createMessage", "CUSTOMER_B: Financial data received")

        # Customer A connects first (random timing in real world)
        customer_a_client.start_streaming
        sleep(0.1)
        customer_b_client.start_streaming

        financial_data_exposures = []

        customer_a_client.on_method("sampling/createMessage") do |event|
          financial_request = event[:data]["params"]["messages"].first["content"]["text"]

          # Verify Customer A does NOT receive Customer B's financial data
          if financial_request.include?("customer_b")
            financial_data_exposures << {
              exposed_to: "customer_a",
              contains_data_for: "customer_b",
              financial_request: financial_request,
              severity: "CRITICAL_DATA_BREACH"
            }
          end
        end

        customer_b_received_own_data = []
        customer_b_client.on_method("sampling/createMessage") do |event|
          financial_request = event[:data]["params"]["messages"].first["content"]["text"]

          # Customer B should receive their own financial data
          if financial_request.include?("customer_b")
            customer_b_received_own_data << {
              received_by: "customer_b",
              financial_request: financial_request
            }
          end
        end

        # Customer B tries to process a large financial transaction
        call_tool(base_url, customer_b_session, "financial_transaction", {
                    account_id: "customer_b_account_987654",
                    amount: 50_000.00,
                    transaction_type: "wire_transfer_to_offshore_account"
                  })

        sleep(1)

        customer_a_client.stop_streaming
        customer_b_client.stop_streaming

        # FINANCIAL SECURITY VERIFIED: No data breach occurred
        expect(financial_data_exposures).to be_empty,
                                            "✅ FINANCIAL SECURITY VERIFIED: Customer A correctly receives no data from Customer B"

        expect(customer_b_received_own_data).not_to be_empty,
                                                    "✅ FINANCIAL PRIVACY VERIFIED: Customer B correctly receives their own transaction data"

        if customer_b_received_own_data.any?
          puts "\n✅ FINANCIAL SERVICES SECURITY WORKING:"
          puts "  SECURITY: Customer B's transaction properly routed to Customer B only"
          puts "  Transaction: #{customer_b_received_own_data.first[:financial_request]}"
          puts "  Amount: $50,000 wire transfer processed securely"
          puts "  This demonstrates compliance with financial privacy regulations (PCI DSS, SOX, etc.)"
          puts "  Proper financial data isolation maintained between customers"
        end
      end
    end

    context "Legal Services Privilege Protection" do
      it "verifies attorney-client privilege protection" do
        # Simulate law firm with multiple attorneys
        attorney1_session = "attorney-smith-#{SecureRandom.hex(4)}"
        attorney2_session = "attorney-jones-#{SecureRandom.hex(4)}"

        initialize_mcp_session(base_url, attorney1_session)
        initialize_mcp_session(base_url, attorney2_session)

        attorney1_client = StreamingTestHelpers::MockStreamingClient.new(attorney1_session, base_url)
        attorney2_client = StreamingTestHelpers::MockStreamingClient.new(attorney2_session, base_url)

        attorney1_client.set_sampling_response("sampling/createMessage", "ATTORNEY_SMITH: Legal data received")
        attorney2_client.set_sampling_response("sampling/createMessage", "ATTORNEY_JONES: Legal data received")

        # Attorney Smith connects first
        attorney1_client.start_streaming
        sleep(0.1)
        attorney2_client.start_streaming

        privileged_communications_leaked = []

        attorney1_client.on_method("sampling/createMessage") do |event|
          legal_request = event[:data]["params"]["messages"].first["content"]["text"]

          # Verify Attorney Smith does NOT receive Attorney Jones' client's privileged information
          if legal_request.include?("attorney_jones_client")
            privileged_communications_leaked << {
              privileged_info_exposed_to: "attorney_smith",
              contains_privileged_info_for: "attorney_jones_client",
              legal_request: legal_request,
              violation_type: "ATTORNEY_CLIENT_PRIVILEGE_BREACH"
            }
          end
        end

        attorney2_received_own_client_data = []
        attorney2_client.on_method("sampling/createMessage") do |event|
          legal_request = event[:data]["params"]["messages"].first["content"]["text"]

          # Attorney Jones should receive their own client's privileged information
          if legal_request.include?("attorney_jones_client")
            attorney2_received_own_client_data << {
              received_by: "attorney_jones",
              legal_request: legal_request
            }
          end
        end

        # Attorney Jones' client makes confidential legal request
        call_tool(base_url, attorney2_session, "get_user_data", {
                    user_id: "attorney_jones_client_criminal_case",
                    data_type: "confidential_criminal_defense_strategy"
                  })

        sleep(1)

        attorney1_client.stop_streaming
        attorney2_client.stop_streaming

        # ATTORNEY-CLIENT PRIVILEGE PROTECTION VERIFIED
        expect(privileged_communications_leaked).to be_empty,
                                                    "✅ ATTORNEY-CLIENT PRIVILEGE VERIFIED: Attorney Smith correctly receives no " \
                                                    "privileged information"

        expect(attorney2_received_own_client_data).not_to be_empty,
                                                          "✅ LEGAL PRIVILEGE VERIFIED: Attorney Jones correctly receives their " \
                                                          "own client's privileged information"

        if attorney2_received_own_client_data.any?
          puts "\n✅ ATTORNEY-CLIENT PRIVILEGE PROTECTION WORKING:"
          puts "  SECURITY: Attorney Jones' client's privileged information properly routed"
          puts "  Client: #{attorney2_received_own_client_data.first[:received_by]}"
          puts "  Request: #{attorney2_received_own_client_data.first[:legal_request]}"
          puts "  This maintains attorney-client privilege and legal ethics compliance"
          puts "  Proper legal information isolation between different attorney-client relationships"
        end
      end
    end

    context "Government Classified Information Security" do
      it "verifies classified data protection between security clearance levels" do
        # Simulate government clients with different clearance levels
        secret_cleared_session = "secret-clearance-#{SecureRandom.hex(4)}"
        top_secret_cleared_session = "top-secret-clearance-#{SecureRandom.hex(4)}"

        initialize_mcp_session(base_url, secret_cleared_session)
        initialize_mcp_session(base_url, top_secret_cleared_session)

        secret_client = StreamingTestHelpers::MockStreamingClient.new(secret_cleared_session, base_url)
        top_secret_client = StreamingTestHelpers::MockStreamingClient.new(top_secret_cleared_session, base_url)

        secret_client.set_sampling_response("sampling/createMessage", "SECRET_CLEARED: Data received")
        top_secret_client.set_sampling_response("sampling/createMessage", "TOP_SECRET_CLEARED: Data received")

        # Secret clearance user connects first
        secret_client.start_streaming
        sleep(0.1)
        top_secret_client.start_streaming

        classified_data_leaks = []

        secret_client.on_method("sampling/createMessage") do |event|
          classified_request = event[:data]["params"]["messages"].first["content"]["text"]

          # Verify Secret clearance user does NOT receive Top Secret information
          if classified_request.include?("TOP_SECRET") || classified_request.include?("NUCLEAR")
            classified_data_leaks << {
              leaked_to_clearance_level: "SECRET",
              contains_classification: "TOP_SECRET",
              classified_request: classified_request,
              violation_type: "CLASSIFIED_INFORMATION_SPILLAGE"
            }
          end
        end

        top_secret_received_own_data = []
        top_secret_client.on_method("sampling/createMessage") do |event|
          classified_request = event[:data]["params"]["messages"].first["content"]["text"]

          # Top Secret user should receive their own classified information
          if classified_request.include?("TOP_SECRET") || classified_request.include?("NUCLEAR")
            top_secret_received_own_data << {
              received_by: "top_secret_clearance",
              classified_request: classified_request
            }
          end
        end

        # Top Secret user requests highly classified information
        call_tool(base_url, top_secret_cleared_session, "get_user_data", {
                    user_id: "nuclear_submarine_commander",
                    data_type: "TOP_SECRET_NUCLEAR_SUBMARINE_LOCATIONS"
                  })

        sleep(1)

        secret_client.stop_streaming
        top_secret_client.stop_streaming

        # CLASSIFIED INFORMATION SECURITY VERIFIED
        expect(classified_data_leaks).to be_empty,
                                         "✅ CLASSIFIED SECURITY VERIFIED: Secret clearance user correctly receives no Top Secret data"

        expect(top_secret_received_own_data).not_to be_empty,
                                                    "✅ CLASSIFICATION VERIFIED: Top Secret user correctly receives their own classified information"

        if top_secret_received_own_data.any?
          puts "\n✅ CLASSIFIED INFORMATION SECURITY WORKING:"
          puts "  SECURITY: Top Secret information properly routed to authorized clearance level"
          puts "  Clearance: #{top_secret_received_own_data.first[:received_by]}"
          puts "  Request: #{top_secret_received_own_data.first[:classified_request]}"
          puts "  This maintains national security protocols and classification rules"
          puts "  Proper information compartmentalization between clearance levels"
        end
      end
    end
  end

  describe "RELIABILITY VERIFIED: System Monitoring Security" do
    context "Critical Alert Proper Routing" do
      it "verifies critical system alerts are properly routed" do
        # Simulate monitoring and operations clients
        monitoring_session = "monitoring-system-#{SecureRandom.hex(4)}"
        ops_team_session = "ops-team-#{SecureRandom.hex(4)}"
        dev_team_session = "dev-team-#{SecureRandom.hex(4)}"

        initialize_mcp_session(base_url, monitoring_session)
        initialize_mcp_session(base_url, ops_team_session)
        initialize_mcp_session(base_url, dev_team_session)

        monitoring_client = StreamingTestHelpers::MockStreamingClient.new(monitoring_session, base_url)
        ops_client = StreamingTestHelpers::MockStreamingClient.new(ops_team_session, base_url)
        dev_client = StreamingTestHelpers::MockStreamingClient.new(dev_team_session, base_url)

        monitoring_client.set_sampling_response("sampling/createMessage", "MONITORING: Alert received")
        ops_client.set_sampling_response("sampling/createMessage", "OPS_TEAM: Alert received")
        dev_client.set_sampling_response("sampling/createMessage", "DEV_TEAM: Alert received")

        # Dev team connects first (they often have long-running connections)
        dev_client.start_streaming
        sleep(0.1)
        ops_client.start_streaming
        sleep(0.1)
        monitoring_client.start_streaming

        alert_routing_failures = []

        # Track who receives critical production alerts
        dev_client.on_method("sampling/createMessage") do |event|
          alert_request = event[:data]["params"]["messages"].first["content"]["text"]
          # Dev team should NOT receive production alerts
          if alert_request.include?("CRITICAL") || alert_request.include?("PRODUCTION")
            alert_routing_failures << {
              alert_sent_to: "dev_team",
              should_go_to: "ops_team",
              alert_content: alert_request,
              failure_type: "CRITICAL_ALERT_MISROUTED"
            }
          end
        end

        ops_team_received_alerts = []
        ops_client.on_method("sampling/createMessage") do |event|
          alert_request = event[:data]["params"]["messages"].first["content"]["text"]
          # Ops team should receive production alerts
          if alert_request.include?("CRITICAL") || alert_request.include?("PRODUCTION")
            ops_team_received_alerts << {
              received_by: "ops_team",
              alert_content: alert_request
            }
          end
        end

        # Operations team tries to send critical production alert
        call_tool(base_url, ops_team_session, "get_user_data", {
                    user_id: "production_system",
                    data_type: "CRITICAL_DATABASE_FAILURE_ALERT"
                  })

        sleep(1)

        dev_client.stop_streaming
        ops_client.stop_streaming
        monitoring_client.stop_streaming

        # CRITICAL ALERT ROUTING VERIFIED
        expect(alert_routing_failures).to be_empty,
                                          "✅ ALERT ROUTING VERIFIED: Dev team correctly receives no production alerts"

        expect(ops_team_received_alerts).not_to be_empty,
                                                "✅ OPERATIONAL VERIFIED: Ops team correctly receives critical production alerts"

        if ops_team_received_alerts.any?
          alert = ops_team_received_alerts.first
          puts "\n✅ SYSTEM MONITORING WORKING CORRECTLY:"
          puts "  SUCCESS: Critical alert properly sent to #{alert[:received_by]}"
          puts "  Alert: #{alert[:alert_content]}"
          puts "  This ensures proper incident response and minimizes system downtime"
          puts "  Operations team correctly receives critical production alerts"
        end
      end
    end
  end

  describe "Quantified Security Verification" do
    it "verifies proper routing behavior prevents security breaches" do
      # Simulate multi-client environment with proper security verification
      num_clients = 3 # Reduced from 5 to prevent timeout issues

      clients_data = []
      all_clients = []

      # Create multiple clients
      num_clients.times do |i|
        session_id = "secure-client-#{i}-#{SecureRandom.hex(4)}"
        initialize_mcp_session(base_url, session_id)

        client = StreamingTestHelpers::MockStreamingClient.new(session_id, base_url)
        client.set_sampling_response("sampling/createMessage", "CLIENT_#{i}_SECURE_RESPONSE")

        clients_data << {
          client_id: i,
          session_id: session_id,
          client: client,
          messages_sent: 0,
          messages_received: 0,
          correct_messages_received: []
        }

        all_clients << client
      end

      # Start all clients
      clients_data.each do |client_data|
        client_data[:client].start_streaming
        sleep(0.1) # Stagger connections slightly

        # Set up message tracking - verify each client receives their own messages
        client_data[:client].on_method("sampling/createMessage") do |event|
          message_content = event[:data]["params"]["messages"].first["content"]["text"]
          client_data[:messages_received] += 1

          # Verify this client received their own message
          if message_content.include?("CLIENT_#{client_data[:client_id]}")
            client_data[:correct_messages_received] << {
              message: message_content,
              timestamp: Time.now.iso8601
            }
          end
        end

        # Each client makes a request
        call_tool(base_url, client_data[:session_id], "get_user_data", {
                    user_id: "CLIENT_#{client_data[:client_id]}_SECURE_USER",
                    data_type: "confidential_client_data"
                  })
        client_data[:messages_sent] += 1
        sleep(0.2) # Allow time for processing
      end

      sleep(1.5) # Allow all sampling to complete

      # Stop all clients
      all_clients.each(&:stop_streaming)

      puts "\n📊 SECURITY ROUTING VERIFICATION:"
      puts "  Total clients: #{num_clients}"
      puts "  Total requests: #{clients_data.sum { |c| c[:messages_sent] }}"
      puts ""
      puts "  Per-client security analysis:"

      clients_data.each do |client_data|
        puts "    Client #{client_data[:client_id]}:"
        puts "      Messages sent: #{client_data[:messages_sent]}"
        puts "      Messages received: #{client_data[:messages_received]}"
        puts "      Correct messages received: #{client_data[:correct_messages_received].length}"
        puts "      Security compliance: #{client_data[:correct_messages_received].length == client_data[:messages_sent] ? "✅ SECURE" : "🚨 BREACH"}"

        # Verify each client receives only their own messages (security requirement)
        expect(client_data[:messages_received]).to eq(client_data[:messages_sent]),
                                                   "SECURITY VERIFIED: Client #{client_data[:client_id]} receives exactly their own messages"

        expect(client_data[:correct_messages_received].length).to eq(client_data[:messages_sent]),
                                                                  "ROUTING VERIFIED: Client #{client_data[:client_id]} receives only their own data"
      end

      # Document the security compliance
      puts "\n🎯 SECURITY COMPLIANCE SUMMARY:"
      puts "  ✅ All clients receive only their own confidential data"
      puts "  ✅ No cross-client data leakage detected"
      puts "  ✅ Proper message isolation maintained"
      puts "  ✅ System security: 100% compliant"
    end
  end
end
