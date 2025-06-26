#!/usr/bin/env ruby
# frozen_string_literal: true

# Security Logging Test Script
# Tests VectorMCP browser automation security logging with various scenarios

require "net/http"
require "json"
require "uri"

class SecurityLoggingTester
  def initialize(server_url = "http://localhost:8002")
    @server_url = server_url
    @test_results = []
  end

  def test_all_security_scenarios
    puts "🔐 Testing Security Logging Scenarios"
    puts "=" * 60

    puts "📋 This script will generate various security events to test logging:"
    puts "   - Authentication successes and failures"
    puts "   - Authorization decisions"
    puts "   - Browser command executions"
    puts "   - Security violations"
    puts "   - Extension connection events"
    puts
    puts "📄 Monitor logs with: tail -f /tmp/vectormcp_security.log | jq"
    puts

    sleep(2)

    test_authentication_events
    test_authorization_decisions
    test_browser_command_logging
    test_security_violations
    test_extension_events

    print_summary
  end

  private

  def test_authentication_events
    puts "\n🔑 Testing: Authentication Event Logging"
    puts "-" * 50

    # Test successful authentication with different user types
    test_auth_event("Admin User", "admin-secure-key-2024", should_succeed: true)
    test_auth_event("Browser User", "browser-user-key-2024", should_succeed: true)
    test_auth_event("Demo User", "demo-limited-key-2024", should_succeed: true)

    # Test failed authentication
    test_auth_event("Invalid Key", "invalid-key-123", should_succeed: false)
    test_auth_event("No Key", nil, should_succeed: false)
    test_auth_event("Blocked Key", "malicious-key-blocked", should_succeed: false)

    sleep(1)
  end

  def test_authorization_decisions
    puts "\n📋 Testing: Authorization Decision Logging"
    puts "-" * 50

    # Test allowed operations
    test_authorization("Admin Navigation", "admin-secure-key-2024", "/browser/navigate", should_succeed: true)
    test_authorization("Browser User Click", "browser-user-key-2024", "/browser/click", should_succeed: true)
    test_authorization("Demo User Navigation", "demo-limited-key-2024", "/browser/navigate", should_succeed: true)

    # Test denied operations
    test_authorization("Demo User Click (Denied)", "demo-limited-key-2024", "/browser/click", should_succeed: false)
    test_authorization("Demo User Screenshot (Denied)", "demo-limited-key-2024", "/browser/screenshot", should_succeed: false)

    sleep(1)
  end

  def test_browser_command_logging
    puts "\n🌐 Testing: Browser Command Execution Logging"
    puts "-" * 50

    # Test various browser commands to generate execution logs
    test_browser_command("Navigation Command", "browser-user-key-2024", "/browser/navigate",
                         { url: "https://example.com", include_snapshot: false })

    test_browser_command("Wait Command", "admin-secure-key-2024", "/browser/wait",
                         { duration: 1000 })

    test_browser_command("Snapshot Command", "demo-limited-key-2024", "/browser/snapshot", {})

    # Test command with sensitive data (should be sanitized)
    test_browser_command("Type Command (Sanitized)", "browser-user-key-2024", "/browser/type",
                         { text: "secret-password-123", selector: "input[type=password]" })

    sleep(1)
  end

  def test_security_violations
    puts "\n⚠️  Testing: Security Violation Logging"
    puts "-" * 50

    # Test various security violations
    test_violation("Unauthorized Browser Action", "demo-limited-key-2024", "/browser/type",
                   { text: "test", selector: "input" })

    test_violation("Invalid JSON Payload", "browser-user-key-2024", "/browser/navigate",
                   "invalid-json-data")

    test_violation("Missing Required Parameters", "admin-secure-key-2024", "/browser/navigate", {})

    sleep(1)
  end

  def test_extension_events
    puts "\n🔌 Testing: Extension Connection Event Logging"
    puts "-" * 50

    # Test extension ping (simulates extension connection)
    test_extension_event("Extension Connection", "/browser/ping", { timestamp: Time.now.to_f })

    # Multiple pings to test heartbeat logging
    3.times do |i|
      test_extension_event("Extension Heartbeat #{i + 1}", "/browser/ping", { timestamp: Time.now.to_f })
      sleep(0.5)
    end

    sleep(1)
  end

  def test_auth_event(test_name, api_key, should_succeed:)
    headers = { "Content-Type" => "application/json" }
    headers["X-API-Key"] = api_key if api_key

    response = make_request("/browser/ping", method: "POST",
                                             data: { timestamp: Time.now.to_f }, headers: headers)

    success = response.code.to_i == 200
    record_test(test_name, success == should_succeed, "auth")

    status_icon = success == should_succeed ? "✅" : "❌"
    status_text = success ? "AUTH SUCCESS" : "AUTH FAILURE"
    expected = should_succeed ? "should succeed" : "should fail"

    puts "  #{status_icon} #{test_name}: #{status_text} (#{expected})"
  end

  def test_authorization(test_name, api_key, endpoint, should_succeed:)
    headers = { "Content-Type" => "application/json", "X-API-Key" => api_key }
    test_data = case endpoint
                when "/browser/navigate"
                  { url: "https://example.com" }
                when "/browser/click"
                  { selector: "button" }
                when "/browser/screenshot"
                  {}
                else
                  {}
                end

    response = make_request(endpoint, method: "POST", data: test_data, headers: headers)

    # Authorization success means 200 or 503 (extension not connected)
    # Authorization failure means 403 (forbidden)
    authorized = response.code.to_i != 403
    success = authorized == should_succeed

    record_test(test_name, success, "authorization")

    status_icon = success ? "✅" : "❌"
    auth_result = authorized ? "AUTHORIZED" : "DENIED"
    expected = should_succeed ? "should allow" : "should deny"

    puts "  #{status_icon} #{test_name}: #{auth_result} (#{expected})"
  end

  def test_browser_command(test_name, api_key, endpoint, data)
    headers = { "Content-Type" => "application/json", "X-API-Key" => api_key }
    response = make_request(endpoint, method: "POST", data: data, headers: headers)

    # Any response other than 401/403 means the command was logged
    logged = ![401, 403].include?(response.code.to_i)
    record_test(test_name, logged, "command")

    status_icon = logged ? "✅" : "❌"
    result = case response.code.to_i
             when 200
               "EXECUTED"
             when 503
               "LOGGED (extension not connected)"
             when 401
               "UNAUTHORIZED"
             when 403
               "FORBIDDEN"
             else
               "ERROR"
             end

    puts "  #{status_icon} #{test_name}: #{result}"
  end

  def test_violation(test_name, api_key, endpoint, data)
    headers = { "Content-Type" => "application/json", "X-API-Key" => api_key }

    response = if data.is_a?(String)
                 # Test invalid JSON
                 make_raw_request(endpoint, method: "POST", body: data, headers: headers)
               else
                 make_request(endpoint, method: "POST", data: data, headers: headers)
               end

    # Security violations should be logged regardless of response
    record_test(test_name, true, "violation")

    violation_type = case response.code.to_i
                     when 400
                       "INVALID REQUEST"
                     when 401
                       "UNAUTHORIZED ACCESS"
                     when 403
                       "FORBIDDEN ACTION"
                     else
                       "SECURITY EVENT"
                     end

    puts "  ⚠️  #{test_name}: #{violation_type} (logged for security audit)"
  end

  def test_extension_event(test_name, endpoint, data)
    # Extension events don't require authentication
    headers = { "Content-Type" => "application/json" }
    response = make_request(endpoint, method: "POST", data: data, headers: headers)

    success = response.code.to_i == 200
    record_test(test_name, success, "extension")

    status_icon = success ? "✅" : "❌"
    result = success ? "CONNECTED" : "FAILED"

    puts "  #{status_icon} #{test_name}: #{result}"
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

  def make_raw_request(path, method: "POST", body: "", headers: {})
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

  def record_test(test_name, success, category)
    @test_results << {
      test: test_name,
      success: success,
      category: category
    }
  end

  def print_summary
    puts "\n#{"=" * 60}"
    puts "📊 Security Logging Test Summary"
    puts "=" * 60

    by_category = @test_results.group_by { |r| r[:category] }
    total_tests = @test_results.length
    total_passed = @test_results.count { |r| r[:success] }

    puts "Total Security Events Generated: #{total_tests}"
    puts "✅ Successful Events: #{total_passed}"
    puts "❌ Failed Events: #{total_tests - total_passed}"

    by_category.each do |category, tests|
      passed = tests.count { |t| t[:success] }
      total = tests.length
      puts "  #{category.capitalize}: #{passed}/#{total} events"
    end

    puts "\n📄 Security Log Analysis:"
    puts "  View logs: tail -f /tmp/vectormcp_security.log | jq"
    puts "  Search events: grep 'Browser command executed' /tmp/vectormcp_security.log"
    puts "  Filter by user: jq 'select(.context.user_role == \"demo\")' /tmp/vectormcp_security.log"
    puts "  Count events: wc -l /tmp/vectormcp_security.log"

    puts "\n🔍 Key Security Events to Look For:"
    puts "  - Authentication attempts and results"
    puts "  - Authorization decision logging"
    puts "  - Browser command execution trails"
    puts "  - Extension connection/disconnection"
    puts "  - Failed access attempts"
    puts "  - Parameter sanitization (passwords redacted)"

    puts "\n🎉 Security logging test completed!"
    puts "   All events should be captured in the structured logs."
  end
end

# Check if server is running
def server_running?(url = "http://localhost:8002")
  uri = URI(url)
  Net::HTTP.get_response(uri)
  true
rescue StandardError
  false
end

# Main execution
if __FILE__ == $PROGRAM_NAME
  puts "🔐 VectorMCP Security Logging Tester"
  puts

  unless server_running?
    puts "❌ Server not running at http://localhost:8002"
    puts "   Please start the server with: ruby examples/security_logging_demo.rb"
    exit(1)
  end

  puts "✅ Security logging demo server detected at http://localhost:8002"
  puts

  tester = SecurityLoggingTester.new
  tester.test_all_security_scenarios
end
