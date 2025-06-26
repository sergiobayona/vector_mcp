#!/usr/bin/env ruby
# frozen_string_literal: true

# Structured Logging Test Script
# Generates various events to demonstrate comprehensive logging capabilities

require "net/http"
require "json"
require "uri"

class StructuredLoggingTester
  def initialize(server_url = "http://localhost:8004")
    @server_url = server_url
    @test_results = []
  end

  def run_comprehensive_logging_test
    puts "📊 VectorMCP Structured Logging Test"
    puts "=" * 60

    puts "This script will generate various events to demonstrate structured logging:"
    puts "  🔍 Browser operations (navigation, clicking, typing)"
    puts "  🔄 Command queue management"
    puts "  🔐 Security events (auth, authorization)"
    puts "  🌐 Transport layer events"
    puts "  ⚠️  Error conditions and edge cases"
    puts
    puts "📄 Monitor logs in another terminal:"
    puts "  tail -f /tmp/vectormcp_operations.log | jq"
    puts "  tail -f /tmp/vectormcp_security.log | jq"
    puts

    sleep(3)

    test_extension_connection_events
    test_browser_operations_logging
    test_security_events_logging  
    test_error_conditions_logging
    test_performance_scenarios
    
    print_summary
  end

  private

  def test_extension_connection_events
    puts "\n🔌 Testing: Extension Connection Events"
    puts "-" * 50
    
    # Simulate extension connection
    test_event("Extension Initial Connection", "/browser/ping", { timestamp: Time.now.to_f })
    
    # Multiple heartbeats
    3.times do |i|
      test_event("Extension Heartbeat #{i + 1}", "/browser/ping", { timestamp: Time.now.to_f })
      sleep(0.5)
    end
    
    # Test command polling
    test_event("Extension Command Poll", "/browser/poll", nil, method: "GET")
  end

  def test_browser_operations_logging
    puts "\n🌐 Testing: Browser Operations Logging"
    puts "-" * 50
    
    api_key = "demo-full-access-2024"
    
    # Navigation operations
    test_operation("Navigation to Example.com", api_key, "/browser/navigate", {
      url: "https://example.com",
      include_snapshot: false
    })
    
    test_operation("Navigation with Snapshot", api_key, "/browser/navigate", {
      url: "https://httpbin.org/json",
      include_snapshot: true
    })
    
    # Interaction operations
    test_operation("Click Operation", api_key, "/browser/click", {
      selector: "button.primary",
      include_snapshot: true
    })
    
    test_operation("Type Operation", api_key, "/browser/type", {
      text: "This is test text for logging demonstration",
      selector: "input[type=text]",
      include_snapshot: true
    })
    
    # Information gathering
    test_operation("Page Snapshot", api_key, "/browser/snapshot", {})
    test_operation("Screenshot Capture", api_key, "/browser/screenshot", {})
    test_operation("Console Logs", api_key, "/browser/console", {})
    
    # Utility operations
    test_operation("Wait Operation", api_key, "/browser/wait", { duration: 1500 })
  end

  def test_security_events_logging
    puts "\n🔐 Testing: Security Events Logging"
    puts "-" * 50
    
    # Test with full access user
    test_security_event("Full Access User - Navigation", "demo-full-access-2024", "/browser/navigate", {
      url: "https://example.com"
    })
    
    test_security_event("Full Access User - Click", "demo-full-access-2024", "/browser/click", {
      selector: "button"
    })
    
    # Test with limited access user
    test_security_event("Limited User - Allowed Navigation", "demo-limited-access-2024", "/browser/navigate", {
      url: "https://example.com"
    })
    
    test_security_event("Limited User - Allowed Snapshot", "demo-limited-access-2024", "/browser/snapshot", {})
    
    test_security_event("Limited User - Denied Click", "demo-limited-access-2024", "/browser/click", {
      selector: "button"
    })
    
    test_security_event("Limited User - Denied Type", "demo-limited-access-2024", "/browser/type", {
      text: "test", selector: "input"
    })
    
    # Authentication failures
    test_security_event("Invalid API Key", "invalid-key-123", "/browser/navigate", {
      url: "https://example.com"
    })
    
    test_security_event("No Authentication", nil, "/browser/navigate", {
      url: "https://example.com"
    })
  end

  def test_error_conditions_logging
    puts "\n⚠️  Testing: Error Conditions Logging"
    puts "-" * 50
    
    api_key = "demo-full-access-2024"
    
    # Invalid JSON payload
    test_error_condition("Invalid JSON Payload", api_key, "/browser/navigate", "invalid-json-data")
    
    # Missing required parameters
    test_error_condition("Missing URL Parameter", api_key, "/browser/navigate", {})
    
    # Invalid endpoint
    test_error_condition("Invalid Endpoint", api_key, "/browser/invalid", { test: true })
    
    # Very large payload (test parameter sanitization)
    large_text = "A" * 2000
    test_operation("Large Text Input", api_key, "/browser/type", {
      text: large_text,
      selector: "input"
    })
  end

  def test_performance_scenarios
    puts "\n📈 Testing: Performance Scenarios"
    puts "-" * 50
    
    api_key = "demo-full-access-2024"
    
    # Rapid consecutive operations
    puts "  🔄 Rapid consecutive operations..."
    5.times do |i|
      test_operation("Rapid Operation #{i + 1}", api_key, "/browser/wait", { duration: 100 })
      sleep(0.1)
    end
    
    # Concurrent-like operations (as fast as possible)
    puts "  ⚡ High-frequency operations..."
    10.times do |i|
      test_operation("High-freq Op #{i + 1}", api_key, "/browser/ping", { timestamp: Time.now.to_f }, method: "POST")
    end
  end

  def test_event(test_name, endpoint, data, method: "POST")
    headers = { "Content-Type" => "application/json" }
    response = make_request(endpoint, method: method, data: data, headers: headers)
    
    success = [200, 202].include?(response.code.to_i)
    record_result(test_name, success, "event")
    
    status = success ? "✅" : "❌"
    puts "  #{status} #{test_name}"
  end

  def test_operation(test_name, api_key, endpoint, data)
    headers = { "Content-Type" => "application/json", "X-API-Key" => api_key }
    
    start_time = Time.now
    response = make_request(endpoint, method: "POST", data: data, headers: headers)
    execution_time = ((Time.now - start_time) * 1000).round(2)
    
    # Consider success if not authentication/authorization failure
    success = ![401, 403].include?(response.code.to_i)
    record_result(test_name, success, "operation")
    
    status = success ? "✅" : "❌"
    result = case response.code.to_i
             when 200
               "SUCCESS"
             when 503
               "QUEUED (extension not connected)"
             when 401
               "UNAUTHORIZED"
             when 403
               "FORBIDDEN"
             else
               "ERROR #{response.code}"
             end
    
    puts "  #{status} #{test_name}: #{result} (#{execution_time}ms)"
  end

  def test_security_event(test_name, api_key, endpoint, data)
    headers = { "Content-Type" => "application/json" }
    headers["X-API-Key"] = api_key if api_key
    
    response = make_request(endpoint, method: "POST", data: data, headers: headers)
    
    # Record for tracking but all security events are "successful" for logging purposes
    record_result(test_name, true, "security")
    
    result = case response.code.to_i
             when 200
               "🟢 ALLOWED"
             when 503
               "🟢 ALLOWED (extension not connected)"
             when 401
               "🔴 UNAUTHORIZED"
             when 403
               "🔴 FORBIDDEN"
             else
               "⚠️ ERROR #{response.code}"
             end
    
    puts "  📝 #{test_name}: #{result}"
  end

  def test_error_condition(test_name, api_key, endpoint, data)
    headers = { "Content-Type" => "application/json", "X-API-Key" => api_key }
    
    if data.is_a?(String)
      # Send raw string for JSON parsing error
      response = make_raw_request(endpoint, body: data, headers: headers)
    else
      response = make_request(endpoint, method: "POST", data: data, headers: headers)
    end
    
    # Error conditions are expected to fail
    error_occurred = [400, 404, 500].include?(response.code.to_i)
    record_result(test_name, error_occurred, "error")
    
    status = error_occurred ? "✅" : "❌"
    result = case response.code.to_i
             when 400
               "BAD REQUEST (logged)"
             when 404
               "NOT FOUND (logged)"
             when 500
               "SERVER ERROR (logged)"
             else
               "UNEXPECTED #{response.code}"
             end
    
    puts "  #{status} #{test_name}: #{result}"
  end

  def make_request(path, method: "GET", data: nil, headers: {})
    uri = URI("#{@server_url}#{path}")
    
    case method.upcase
    when "GET"
      request = Net::HTTP::Get.new(uri)
    when "POST"
      request = Net::HTTP::Post.new(uri)
    else
      raise "Unsupported method: #{method}"
    end

    headers.each { |key, value| request[key] = value }
    request.body = data.to_json if data && method.upcase == "POST"

    Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.read_timeout = 5
      http.open_timeout = 5
      http.request(request)
    end
  rescue StandardError => e
    OpenStruct.new(code: "500", body: { error: e.message }.to_json)
  end

  def make_raw_request(path, body: "", headers: {})
    uri = URI("#{@server_url}#{path}")
    request = Net::HTTP::Post.new(uri)
    headers.each { |key, value| request[key] = value }
    request.body = body

    Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.read_timeout = 5
      http.open_timeout = 5
      http.request(request)
    end
  rescue StandardError => e
    OpenStruct.new(code: "500", body: { error: e.message }.to_json)
  end

  def record_result(test_name, success, category)
    @test_results << {
      test: test_name,
      success: success,
      category: category
    }
  end

  def print_summary
    puts "\n" + "=" * 60
    puts "📊 Structured Logging Test Summary"
    puts "=" * 60

    by_category = @test_results.group_by { |r| r[:category] }
    total_events = @test_results.length

    puts "Total Events Generated: #{total_events}"
    
    by_category.each do |category, results|
      successful = results.count { |r| r[:success] }
      total = results.length
      puts "  #{category.capitalize}: #{successful}/#{total} events"
    end

    puts
    puts "📄 Log Analysis Commands:"
    puts "  # View all operations logs"
    puts "  tail -f /tmp/vectormcp_operations.log | jq"
    puts
    puts "  # Security events only"
    puts "  tail -f /tmp/vectormcp_security.log | jq"
    puts
    puts "  # Filter by component"
    puts "  jq 'select(.component == \"browser.operations\")' /tmp/vectormcp_operations.log"
    puts "  jq 'select(.component == \"browser.queue\")' /tmp/vectormcp_operations.log"
    puts "  jq 'select(.component == \"security.browser\")' /tmp/vectormcp_operations.log"
    puts
    puts "  # Performance analysis"
    puts "  jq 'select(.context.execution_time_ms > 100)' /tmp/vectormcp_operations.log"
    puts
    puts "  # User activity tracking"
    puts "  jq 'select(.context.user_id == \"demo_user_full\")' /tmp/vectormcp_operations.log"
    puts
    puts "  # Error analysis"
    puts "  jq 'select(.level == \"ERROR\")' /tmp/vectormcp_operations.log"
    
    puts
    puts "🎉 Structured logging test completed!"
    puts "   Check the log files to see detailed structured data for each event."
  end
end

# Check if server is running
def server_running?(url = "http://localhost:8004")
  uri = URI(url)
  Net::HTTP.get_response(uri)
  true
rescue StandardError
  false
end

# Main execution
if __FILE__ == $0
  puts "📊 VectorMCP Structured Logging Tester"
  puts

  unless server_running?
    puts "❌ Server not running at http://localhost:8004"
    puts "   Please start the server with: ruby examples/structured_logging_demo.rb"
    exit(1)
  end

  puts "✅ Structured logging demo server detected at http://localhost:8004"
  
  tester = StructuredLoggingTester.new
  tester.run_comprehensive_logging_test
end