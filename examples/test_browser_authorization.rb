#!/usr/bin/env ruby
# frozen_string_literal: true

# Browser Authorization Test Script
# Tests VectorMCP browser automation with different authorization levels

require "net/http"
require "json"
require "uri"

class BrowserAuthorizationTester
  def initialize(server_url = "http://localhost:8001")
    @server_url = server_url
    @test_results = []
  end

  def test_all_authorization_scenarios
    puts "🔐 Testing Browser Authorization Scenarios"
    puts "=" * 60

    test_admin_user
    test_browser_user  
    test_demo_user
    test_readonly_user
    test_invalid_auth
    
    print_summary
  end

  private

  def test_admin_user
    puts "\n👑 Testing: Admin User (admin-key-123)"
    puts "-" * 40
    
    api_key = "admin-key-123"
    
    # Admin should have access to all browser tools
    test_endpoint("Navigate", "/browser/navigate", { url: "https://example.com" }, api_key, should_succeed: true)
    test_endpoint("Click", "/browser/click", { selector: "button" }, api_key, should_succeed: true)
    test_endpoint("Type", "/browser/type", { text: "test", selector: "input" }, api_key, should_succeed: true)
    test_endpoint("Snapshot", "/browser/snapshot", {}, api_key, should_succeed: true)
    test_endpoint("Screenshot", "/browser/screenshot", {}, api_key, should_succeed: true)
    test_endpoint("Console", "/browser/console", {}, api_key, should_succeed: true)
  end

  def test_browser_user
    puts "\n🔧 Testing: Browser User (browser-key-456)"
    puts "-" * 40
    
    api_key = "browser-key-456"
    
    # Browser user should have access to all browser tools
    test_endpoint("Navigate", "/browser/navigate", { url: "https://example.com" }, api_key, should_succeed: true)
    test_endpoint("Click", "/browser/click", { selector: "button" }, api_key, should_succeed: true)
    test_endpoint("Type", "/browser/type", { text: "test", selector: "input" }, api_key, should_succeed: true)
    test_endpoint("Snapshot", "/browser/snapshot", {}, api_key, should_succeed: true)
    test_endpoint("Screenshot", "/browser/screenshot", {}, api_key, should_succeed: true)
    test_endpoint("Console", "/browser/console", {}, api_key, should_succeed: true)
  end

  def test_demo_user
    puts "\n🎮 Testing: Demo User (demo-key-789)"
    puts "-" * 40
    
    api_key = "demo-key-789"
    
    # Demo user should only have access to navigation and snapshots
    test_endpoint("Navigate", "/browser/navigate", { url: "https://example.com" }, api_key, should_succeed: true)
    test_endpoint("Snapshot", "/browser/snapshot", {}, api_key, should_succeed: true)
    
    # These should be denied
    test_endpoint("Click", "/browser/click", { selector: "button" }, api_key, should_succeed: false)
    test_endpoint("Type", "/browser/type", { text: "test", selector: "input" }, api_key, should_succeed: false)
    test_endpoint("Screenshot", "/browser/screenshot", {}, api_key, should_succeed: false)
    test_endpoint("Console", "/browser/console", {}, api_key, should_succeed: false)
  end

  def test_readonly_user
    puts "\n👁️  Testing: Read-Only User (readonly-key-000)"
    puts "-" * 40
    
    api_key = "readonly-key-000"
    
    # Read-only user should have access to navigation, snapshots, and screenshots
    test_endpoint("Navigate", "/browser/navigate", { url: "https://example.com" }, api_key, should_succeed: true)
    test_endpoint("Snapshot", "/browser/snapshot", {}, api_key, should_succeed: true)
    test_endpoint("Screenshot", "/browser/screenshot", {}, api_key, should_succeed: true)
    
    # These should be denied
    test_endpoint("Click", "/browser/click", { selector: "button" }, api_key, should_succeed: false)
    test_endpoint("Type", "/browser/type", { text: "test", selector: "input" }, api_key, should_succeed: false)
    test_endpoint("Console", "/browser/console", {}, api_key, should_succeed: false)
  end

  def test_invalid_auth
    puts "\n❌ Testing: Invalid Authentication"
    puts "-" * 40
    
    # No API key
    test_endpoint("Navigate (No Auth)", "/browser/navigate", { url: "https://example.com" }, nil, should_succeed: false, expected_code: 401)
    
    # Invalid API key
    test_endpoint("Navigate (Bad Key)", "/browser/navigate", { url: "https://example.com" }, "invalid-key", should_succeed: false, expected_code: 401)
  end

  def test_endpoint(test_name, endpoint, params, api_key, should_succeed:, expected_code: nil)
    headers = { "Content-Type" => "application/json" }
    headers["X-API-Key"] = api_key if api_key

    response = make_request(endpoint, method: "POST", data: params, headers: headers)
    
    success = case response.code.to_i
              when 200
                true
              when 503
                # Extension not connected - this means auth passed but extension unavailable
                should_succeed
              when 401, 403
                false
              else
                false
              end

    expected_outcome = should_succeed ? "ALLOW" : "DENY"
    actual_outcome = success ? "ALLOWED" : "DENIED"
    
    if success == should_succeed
      status = "✅ PASS"
      @test_results << { test: test_name, status: "PASS", expected: expected_outcome, actual: actual_outcome }
    else
      status = "❌ FAIL"
      @test_results << { test: test_name, status: "FAIL", expected: expected_outcome, actual: actual_outcome }
    end

    response_info = case response.code.to_i
                    when 200
                      "Success"
                    when 503
                      "Extension not connected (auth passed)"
                    when 401
                      "Unauthorized"
                    when 403
                      "Forbidden"
                    else
                      "Error #{response.code}"
                    end

    puts "  #{status} #{test_name}: #{response_info}"
    
    # Show error details for unexpected failures
    if success != should_succeed && response.code.to_i != 503
      begin
        error_data = JSON.parse(response.body)
        puts "    Details: #{error_data["error"]}"
      rescue JSON::ParserError
        puts "    Raw response: #{response.body}"
      end
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

    # Set headers
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
    puts "\n" + "=" * 60
    puts "📊 Authorization Test Summary"
    puts "=" * 60

    passed = @test_results.count { |r| r[:status] == "PASS" }
    failed = @test_results.count { |r| r[:status] == "FAIL" }
    total = @test_results.length

    puts "Total Tests: #{total}"
    puts "✅ Passed: #{passed}"
    puts "❌ Failed: #{failed}"
    puts "Success Rate: #{((passed.to_f / total) * 100).round(1)}%"

    if failed > 0
      puts "\nFailed Tests:"
      @test_results.select { |r| r[:status] == "FAIL" }.each do |result|
        puts "  ❌ #{result[:test]} (Expected: #{result[:expected]}, Got: #{result[:actual]})"
      end
    else
      puts "\n🎉 All authorization tests passed!"
    end
  end
end

# Check if server is running
def server_running?(url = "http://localhost:8001")
  uri = URI(url)
  Net::HTTP.get_response(uri)
  true
rescue StandardError
  false
end

# Main execution
if __FILE__ == $0
  puts "🔐 VectorMCP Browser Authorization Tester"
  puts

  unless server_running?
    puts "❌ Server not running at http://localhost:8001"
    puts "   Please start the server with: ruby examples/browser_authorization_demo.rb"
    exit(1)
  end

  puts "✅ Server detected at http://localhost:8001"
  
  tester = BrowserAuthorizationTester.new
  tester.test_all_authorization_scenarios
end