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
        required: ["user_id", "data_type"]
      }
    ) do |args, session|
      # This simulates fetching sensitive user data via sampling
      result = session.sample({
                                messages: [
                                  {
                                    role: "system",
                                    content: {
                                      type: "text", 
                                      text: "Retrieve #{args['data_type']} for user #{args['user_id']}"
                                    }
                                  }
                                ],
                                system_prompt: "You are a secure data retrieval system.",
                                max_tokens: 200
                              })

      {
        user_id: args["user_id"],
        data_type: args["data_type"], 
        sensitive_data: "CONFIDENTIAL: User #{args['user_id']} #{args['data_type']} data",
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
        required: ["account_id", "amount", "transaction_type"]
      }
    ) do |args, session|
      # Financial data that must not leak to other clients
      result = session.sample({
                                messages: [
                                  {
                                    role: "system",
                                    content: {
                                      type: "text",
                                      text: "Process #{args['transaction_type']} of $#{args['amount']} for account #{args['account_id']}"
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
        financial_data: "CONFIDENTIAL: Account #{args['account_id']} balance and transaction history",
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

  describe "SECURITY CRITICAL: Data Leakage Scenarios" do
    context "Healthcare Data Breach Simulation" do
      it "demonstrates HIPAA violation through routing flaw" do
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
        patient_response = call_tool(base_url, patient_session, "get_user_data", {
                                      user_id: "patient_123",
                                      data_type: "medical_records_blood_test_results"
                                    })

        sleep(1)

        doctor_client.stop_streaming
        patient_client.stop_streaming

        # HIPAA VIOLATION: Doctor receives patient's private medical request
        expect(doctor_received_data).not_to be_empty,
          "🚨 HIPAA VIOLATION: Doctor received patient's private medical data request"
        
        expect(patient_received_data).to be_empty,
          "🚨 PRIVACY VIOLATION: Patient never received their own medical data"

        if doctor_received_data.any?
          puts "\n🚨 HEALTHCARE DATA BREACH SIMULATION:"
          puts "  VIOLATION: Doctor client received patient's private medical request"
          puts "  Request: #{doctor_received_data.first[:medical_request]}"
          puts "  This represents a HIPAA violation and potential lawsuit"
          puts "  Patient's medical privacy has been compromised"
        end
      end
    end

    context "Financial Services Data Exposure" do
      it "demonstrates financial data leakage between customer accounts" do
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
          
          # Customer A receives Customer B's financial transaction request
          if financial_request.include?("customer_b")
            financial_data_exposures << {
              exposed_to: "customer_a",
              contains_data_for: "customer_b", 
              financial_request: financial_request,
              severity: "CRITICAL_DATA_BREACH"
            }
          end
        end

        # Customer B tries to process a large financial transaction
        transaction_response = call_tool(base_url, customer_b_session, "financial_transaction", {
                                          account_id: "customer_b_account_987654",
                                          amount: 50000.00,
                                          transaction_type: "wire_transfer_to_offshore_account"
                                        })

        sleep(1)

        customer_a_client.stop_streaming
        customer_b_client.stop_streaming

        # FINANCIAL DATA BREACH
        expect(financial_data_exposures).not_to be_empty,
          "🚨 FINANCIAL DATA BREACH: Customer A exposed to Customer B's transaction"

        if financial_data_exposures.any?
          exposure = financial_data_exposures.first
          puts "\n🚨 FINANCIAL SERVICES DATA BREACH:"
          puts "  VIOLATION: #{exposure[:exposed_to]} received financial data for #{exposure[:contains_data_for]}"
          puts "  Transaction: #{exposure[:financial_request]}"
          puts "  Amount: $50,000 wire transfer"
          puts "  This violates financial privacy regulations (PCI DSS, SOX, etc.)"
          puts "  Could result in regulatory fines and loss of banking license"
        end
      end
    end

    context "Legal Services Client Privilege Violation" do
      it "demonstrates attorney-client privilege breach" do
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
          
          # Attorney Smith receives Attorney Jones' client's privileged information
          if legal_request.include?("attorney_jones_client")
            privileged_communications_leaked << {
              privileged_info_exposed_to: "attorney_smith",
              contains_privileged_info_for: "attorney_jones_client",
              legal_request: legal_request,
              violation_type: "ATTORNEY_CLIENT_PRIVILEGE_BREACH"
            }
          end
        end

        # Attorney Jones' client makes confidential legal request
        legal_response = call_tool(base_url, attorney2_session, "get_user_data", {
                                    user_id: "attorney_jones_client_criminal_case",
                                    data_type: "confidential_criminal_defense_strategy"
                                  })

        sleep(1)

        attorney1_client.stop_streaming
        attorney2_client.stop_streaming

        # ATTORNEY-CLIENT PRIVILEGE VIOLATION
        expect(privileged_communications_leaked).not_to be_empty,
          "🚨 ATTORNEY-CLIENT PRIVILEGE BREACH: Confidential legal information exposed"

        if privileged_communications_leaked.any?
          breach = privileged_communications_leaked.first
          puts "\n🚨 ATTORNEY-CLIENT PRIVILEGE VIOLATION:"
          puts "  VIOLATION: #{breach[:privileged_info_exposed_to]} received privileged information"
          puts "  Client: #{breach[:contains_privileged_info_for]}"
          puts "  Request: #{breach[:legal_request]}"
          puts "  This violates attorney-client privilege and legal ethics rules"
          puts "  Could result in disbarment, mistrial, and malpractice lawsuits"
        end
      end
    end

    context "Government Classified Information Breach" do
      it "demonstrates classified data exposure between security clearance levels" do
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
          
          # Secret clearance user receives Top Secret information
          if classified_request.include?("TOP_SECRET") || classified_request.include?("NUCLEAR")
            classified_data_leaks << {
              leaked_to_clearance_level: "SECRET",
              contains_classification: "TOP_SECRET", 
              classified_request: classified_request,
              violation_type: "CLASSIFIED_INFORMATION_SPILLAGE"
            }
          end
        end

        # Top Secret user requests highly classified information
        classified_response = call_tool(base_url, top_secret_cleared_session, "get_user_data", {
                                         user_id: "nuclear_submarine_commander",
                                         data_type: "TOP_SECRET_NUCLEAR_SUBMARINE_LOCATIONS"
                                       })

        sleep(1)

        secret_client.stop_streaming
        top_secret_client.stop_streaming

        # CLASSIFIED INFORMATION SPILLAGE
        expect(classified_data_leaks).not_to be_empty,
          "🚨 CLASSIFIED INFORMATION BREACH: Top Secret data exposed to Secret clearance"

        if classified_data_leaks.any?
          leak = classified_data_leaks.first
          puts "\n🚨 CLASSIFIED INFORMATION SPILLAGE:"
          puts "  VIOLATION: #{leak[:contains_classification]} information exposed to #{leak[:leaked_to_clearance_level]} clearance"
          puts "  Request: #{leak[:classified_request]}"
          puts "  This violates national security protocols and classification rules"
          puts "  Could result in criminal charges, loss of clearance, and national security damage"
        end
      end
    end
  end

  describe "RELIABILITY CRITICAL: System Monitoring Failures" do
    context "Critical Alert Misrouting" do
      it "demonstrates how critical system alerts can be missed" do
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
          if alert_request.include?("CRITICAL") || alert_request.include?("PRODUCTION")
            alert_routing_failures << {
              alert_sent_to: "dev_team",
              should_go_to: "ops_team", 
              alert_content: alert_request,
              failure_type: "CRITICAL_ALERT_MISROUTED"
            }
          end
        end

        ops_client.on_method("sampling/createMessage") do |event|
          # Ops team should receive this but won't due to routing flaw
        end

        # Operations team tries to send critical production alert  
        alert_response = call_tool(base_url, ops_team_session, "get_user_data", {
                                    user_id: "production_system",
                                    data_type: "CRITICAL_DATABASE_FAILURE_ALERT"
                                  })

        sleep(1)

        dev_client.stop_streaming
        ops_client.stop_streaming
        monitoring_client.stop_streaming

        # CRITICAL ALERT MISROUTING
        expect(alert_routing_failures).not_to be_empty,
          "🚨 CRITICAL ALERT FAILURE: Production alert sent to dev team instead of ops team"

        if alert_routing_failures.any?
          failure = alert_routing_failures.first
          puts "\n🚨 SYSTEM MONITORING FAILURE:"
          puts "  FAILURE: Critical alert sent to #{failure[:alert_sent_to]} instead of #{failure[:should_go_to]}"
          puts "  Alert: #{failure[:alert_content]}"
          puts "  This could result in extended system downtime and SLA violations"
          puts "  Operations team never receives critical production alerts"
        end
      end
    end
  end

  describe "Quantified Impact Assessment" do
    it "measures the probability and impact of routing failures" do
      # Simulate realistic multi-client environment
      num_clients = 5
      num_requests_per_client = 10
      
      clients_data = []
      all_clients = []

      # Create multiple clients
      num_clients.times do |i|
        session_id = "impact-client-#{i}-#{SecureRandom.hex(4)}"
        initialize_mcp_session(base_url, session_id)
        
        client = StreamingTestHelpers::MockStreamingClient.new(session_id, base_url)
        client.set_sampling_response("sampling/createMessage", "CLIENT_#{i}_RESPONSE")
        
        clients_data << {
          client_id: i,
          session_id: session_id,
          client: client,
          messages_sent: 0,
          messages_received: 0,
          wrong_messages_received: []
        }
        
        all_clients << client
      end

      # Start all clients (connection order determines routing)
      clients_data.each_with_index do |client_data, index|
        client_data[:client].start_streaming
        sleep(0.05) # Stagger connections slightly
        
        # Set up message tracking
        client_data[:client].on_method("sampling/createMessage") do |event|
          message_content = event[:data]["params"]["messages"].first["content"]["text"]
          client_data[:messages_received] += 1
          
          # Detect if this client received a message intended for another client
          (0...num_clients).each do |other_client_id|
            if other_client_id != client_data[:client_id] && message_content.include?("CLIENT_#{other_client_id}")
              client_data[:wrong_messages_received] << {
                intended_for_client: other_client_id,
                message: message_content,
                timestamp: Time.now.iso8601
              }
            end
          end
        end
      end

      # Each client makes multiple requests
      total_requests = 0
      clients_data.each do |client_data|
        num_requests_per_client.times do |req_num|
          call_tool(base_url, client_data[:session_id], "get_user_data", {
                      user_id: "CLIENT_#{client_data[:client_id]}_USER",
                      data_type: "client_specific_data_request_#{req_num}"
                    })
          client_data[:messages_sent] += 1
          total_requests += 1
          sleep(0.1)
        end
      end

      sleep(2) # Allow all sampling to complete

      # Stop all clients
      all_clients.each(&:stop_streaming)

      # Analyze routing behavior
      total_wrong_routes = 0
      routing_analysis = []

      clients_data.each do |client_data|
        wrong_message_count = client_data[:wrong_messages_received].length
        total_wrong_routes += wrong_message_count
        
        routing_analysis << {
          client_id: client_data[:client_id],
          messages_sent: client_data[:messages_sent],
          messages_received: client_data[:messages_received], 
          wrong_messages_received: wrong_message_count,
          routing_accuracy: client_data[:messages_sent] > 0 ? 
            ((client_data[:messages_received].to_f / client_data[:messages_sent]) * 100).round(2) : 0
        }
      end

      puts "\n📊 ROUTING FAILURE IMPACT ASSESSMENT:"
      puts "  Total clients: #{num_clients}"
      puts "  Total requests: #{total_requests}"
      puts "  Total routing failures: #{total_wrong_routes}"
      puts "  Failure rate: #{((total_wrong_routes.to_f / total_requests) * 100).round(2)}%"
      puts ""
      puts "  Per-client analysis:"
      
      routing_analysis.each do |analysis|
        puts "    Client #{analysis[:client_id]}:"
        puts "      Messages sent: #{analysis[:messages_sent]}"
        puts "      Messages received: #{analysis[:messages_received]}"
        puts "      Wrong messages received: #{analysis[:wrong_messages_received]}"
        puts "      Routing accuracy: #{analysis[:routing_accuracy]}%"
      end

      # The first client typically receives ALL messages due to the routing flaw
      first_client_data = clients_data.first
      expect(first_client_data[:messages_received]).to be > first_client_data[:messages_sent],
        "ROUTING FLAW: First client receives messages from other clients"

      # Other clients typically receive NO messages
      other_clients = clients_data[1..-1]
      other_clients.each do |client_data|
        expect(client_data[:messages_received]).to eq(0),
          "ROUTING FLAW: Client #{client_data[:client_id]} receives no messages, not even its own"
      end

      # Document the impact
      puts "\n🎯 IMPACT SUMMARY:"
      puts "  - First connected client receives #{first_client_data[:messages_received]} messages (#{first_client_data[:wrong_messages_received].length} not intended for them)"
      puts "  - #{other_clients.length} clients receive no messages at all"
      puts "  - #{total_wrong_routes} messages delivered to wrong recipients"
      puts "  - System reliability: #{100 - ((total_wrong_routes.to_f / total_requests) * 100).round(2)}%"
    end
  end
end