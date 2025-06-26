#!/usr/bin/env ruby
# frozen_string_literal: true

# No Security Test Script
# Verifies that browser automation works without any security features

require "net/http"
require "json"
require "uri"

class NoSecurityTester
  def initialize(server_url = "http://localhost:8003")
    @server_url = server_url
    @test_results = []
  end

  def test_all_endpoints_without_auth
    puts "🔓 Testing Browser Automation Without Security"
    puts "=" * 60

    puts "📋 This script verifies that all browser endpoints work without authentication"
    puts "   No X-API-Key headers or Authorization headers will be sent"
    puts

    test_extension_endpoints
    test_browser_commands

    print_summary
  end

  private

  def test_extension_endpoints
    puts "\n🔌 Testing: Extension Endpoints (No Auth)"
    puts "-" * 40

    # Test extension ping
    test_endpoint("Extension Ping", "/browser/ping", { timestamp: Time.now.to_f }, method: "POST")

    # Test extension poll
    test_endpoint("Extension Poll", "/browser/poll", nil, method: "GET")

    # Test extension result submission
    test_endpoint("Extension Result", "/browser/result", {
                    command_id: "test-123",
                    success: true,
                    result: { test: "data" }
                  }, method: "POST")
  end

  def test_browser_commands
    puts "\n🌐 Testing: Browser Commands (No Auth)"
    puts "-" * 40

    # Test all browser automation commands without authentication
    test_endpoint("Navigate", "/browser/navigate", { url: "https://example.com" }, method: "POST")
    test_endpoint("Click", "/browser/click", { selector: "button" }, method: "POST")
    test_endpoint("Type", "/browser/type", { text: "test", selector: "input" }, method: "POST")
    test_endpoint("Snapshot", "/browser/snapshot", {}, method: "POST")
    test_endpoint("Screenshot", "/browser/screenshot", {}, method: "POST")
    test_endpoint("Console", "/browser/console", {}, method: "POST")
    test_endpoint("Wait", "/browser/wait", { duration: 1000 }, method: "POST")
  end

  def test_endpoint(test_name, endpoint, data, method: "POST")
    # NO authentication headers - this is the key test
    headers = { "Content-Type" => "application/json" }

    response = make_request(endpoint, method: method, data: data, headers: headers)

    # Success means we didn't get 401 (Unauthorized) or 403 (Forbidden)
    success = ![401, 403].include?(response.code.to_i)

    @test_results << { test: test_name, success: success, code: response.code.to_i }

    status_icon = success ? "✅" : "❌"
    result_text = case response.code.to_i
                  when 200
                    "SUCCESS"
                  when 503
                    "SUCCESS (extension not connected)"
                  when 405
                    "SUCCESS (method not allowed - expected for some endpoints)"
                  when 401
                    "FAILED (requires auth - this shouldn't happen!)"
                  when 403
                    "FAILED (forbidden - this shouldn't happen!)"
                  when 400
                    "SUCCESS (bad request - endpoint accessible)"
                  else
                    "UNKNOWN (#{response.code})"
                  end

    puts "  #{status_icon} #{test_name}: #{result_text}"

    # Show details for unexpected failures
    return unless [401, 403].include?(response.code.to_i)

    begin
      error_data = JSON.parse(response.body)
      puts "    ⚠️  ERROR: #{error_data["error"]}"
    rescue JSON::ParserError
      puts "    ⚠️  ERROR: #{response.body}"
    end
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

    # Set headers (importantly, NO authentication headers)
    headers.each { |key, value| request[key] = value }

    # Set body for POST requests
    request.body = data.to_json if data && method.upcase == "POST"

    # Make the request
    Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.read_timeout = 5
      http.open_timeout = 5
      http.request(request)
    end
  rescue StandardError => e
    puts "❌ REQUEST FAILED: #{e.message}"
    OpenStruct.new(code: "500", body: { error: e.message }.to_json)
  end

  def print_summary
    puts "\n#{"=" * 60}"
    puts "📊 No Security Test Summary"
    puts "=" * 60

    total_tests = @test_results.length
    successful_tests = @test_results.count { |r| r[:success] }
    auth_failures = @test_results.count { |r| [401, 403].include?(r[:code]) }

    puts "Total Tests: #{total_tests}"
    puts "✅ Accessible Without Auth: #{successful_tests}"
    puts "❌ Require Auth (unexpected): #{auth_failures}"

    if auth_failures.positive?
      puts "\n⚠️  SECURITY ISSUE: Some endpoints require authentication when they shouldn't!"
      puts "   Browser automation should work without security when security is disabled."

      @test_results.select { |r| [401, 403].include?(r[:code]) }.each do |result|
        puts "   - #{result[:test]} returned #{result[:code]}"
      end
    else
      puts "\n✅ SUCCESS: All browser endpoints are accessible without authentication!"
      puts "   Browser automation works correctly when security is disabled."
    end

    puts "\n🔓 Security Status: DISABLED (as expected)"
    puts "   - No authentication required"
    puts "   - No authorization checks"
    puts "   - All endpoints publicly accessible"

    if successful_tests == total_tests
      puts "\n🎉 Browser automation works perfectly without security!"
      puts "   Users can opt out of security features and still use all browser tools."
    else
      puts "\n⚠️  Some issues detected - check server configuration."
    end
  end
end

# Check if server is running
def server_running?(url = "http://localhost:8003")
  uri = URI(url)
  Net::HTTP.get_response(uri)
  true
rescue StandardError
  false
end

# Main execution
if __FILE__ == $PROGRAM_NAME
  puts "🔓 VectorMCP No Security Tester"
  puts

  unless server_running?
    puts "❌ Server not running at http://localhost:8003"
    puts "   Please start the server with: ruby examples/simple_browser_server_no_security.rb"
    exit(1)
  end

  puts "✅ No-security server detected at http://localhost:8003"

  tester = NoSecurityTester.new
  tester.test_all_endpoints_without_auth
end
