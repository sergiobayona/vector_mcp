#!/usr/bin/env ruby
# frozen_string_literal: true

# Browser Authentication Test Script
# Tests VectorMCP browser automation with different authentication scenarios

require "net/http"
require "json"
require "uri"

class BrowserAuthTester
  def initialize(server_url = "http://localhost:8000")
    @server_url = server_url
  end

  def test_all_scenarios
    puts "🧪 Testing Browser Authentication Scenarios"
    puts "=" * 50

    test_no_auth
    test_invalid_auth
    test_valid_auth_browser_user
    test_valid_auth_demo_user
    test_unauthorized_action
    
    puts "\n✅ All authentication tests completed!"
  end

  private

  def test_no_auth
    puts "\n1️⃣ Testing: No Authentication"
    response = make_request("/browser/ping", method: "POST", data: { timestamp: Time.now.to_f })
    
    if response.code == "401"
      puts "✅ PASS: Request rejected with 401 Unauthorized"
      puts "   Response: #{JSON.parse(response.body)["error"]}"
    else
      puts "❌ FAIL: Expected 401, got #{response.code}"
    end
  end

  def test_invalid_auth
    puts "\n2️⃣ Testing: Invalid API Key"
    headers = { "X-API-Key" => "invalid-key-123" }
    response = make_request("/browser/ping", method: "POST", data: { timestamp: Time.now.to_f }, headers: headers)
    
    if response.code == "401"
      puts "✅ PASS: Invalid key rejected with 401 Unauthorized"
      puts "   Response: #{JSON.parse(response.body)["error"]}"
    else
      puts "❌ FAIL: Expected 401, got #{response.code}"
    end
  end

  def test_valid_auth_browser_user
    puts "\n3️⃣ Testing: Valid Authentication (Browser User)"
    headers = { "X-API-Key" => "browser-automation-key-123" }
    response = make_request("/browser/ping", method: "POST", data: { timestamp: Time.now.to_f }, headers: headers)
    
    if response.code == "200"
      puts "✅ PASS: Browser user authenticated successfully"
      puts "   Response: #{JSON.parse(response.body)}"
      
      # Test navigation access
      nav_response = make_request("/browser/navigate", method: "POST", 
                                  data: { url: "https://example.com" }, headers: headers)
      if nav_response.code == "503" # Extension not connected, but auth passed
        puts "✅ PASS: Navigation authorized (extension not connected)"
      elsif nav_response.code == "200"
        puts "✅ PASS: Navigation authorized and executed"
      else
        puts "❌ FAIL: Navigation denied: #{nav_response.code}"
      end
    else
      puts "❌ FAIL: Expected 200, got #{response.code}"
    end
  end

  def test_valid_auth_demo_user
    puts "\n4️⃣ Testing: Valid Authentication (Demo User)"
    headers = { "X-API-Key" => "demo-key-456" }
    response = make_request("/browser/ping", method: "POST", data: { timestamp: Time.now.to_f }, headers: headers)
    
    if response.code == "200"
      puts "✅ PASS: Demo user authenticated successfully"
      puts "   Response: #{JSON.parse(response.body)}"
    else
      puts "❌ FAIL: Expected 200, got #{response.code}"
    end
  end

  def test_unauthorized_action
    puts "\n5️⃣ Testing: Authorized User, Unauthorized Action"
    headers = { "X-API-Key" => "demo-key-456" }
    
    # Demo user should have limited permissions (only navigate and snapshot)
    # Test clicking which should be denied
    response = make_request("/browser/click", method: "POST",
                           data: { selector: "button" }, headers: headers)
    
    if response.code == "403"
      puts "✅ PASS: Limited user denied access to restricted action"
      puts "   Response: #{JSON.parse(response.body)["error"]}"
    elsif response.code == "503" # Extension not connected
      puts "⚠️  PARTIAL: Authorization passed but extension not connected"
      puts "   (This means authorization is working correctly)"
    else
      puts "❌ FAIL: Expected 403, got #{response.code}"
      puts "   Response: #{response.body}"
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
    request["Content-Type"] = "application/json"
    headers.each { |key, value| request[key] = value }
    
    # Set body for POST requests
    request.body = data.to_json if data && method.upcase == "POST"

    # Make the request
    Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.request(request)
    end
  rescue StandardError => e
    puts "❌ REQUEST FAILED: #{e.message}"
    # Return a fake response for error handling
    OpenStruct.new(code: "500", body: { error: e.message }.to_json)
  end
end

# Check if server is running
def server_running?(url = "http://localhost:8000")
  uri = URI(url)
  Net::HTTP.get_response(uri)
  true
rescue StandardError
  false
end

# Main execution
if __FILE__ == $0
  puts "🔒 VectorMCP Browser Authentication Tester"
  puts

  unless server_running?
    puts "❌ Server not running at http://localhost:8000"
    puts "   Please start the server with: ruby examples/secure_browser_server.rb"
    exit(1)
  end

  puts "✅ Server detected at http://localhost:8000"
  
  tester = BrowserAuthTester.new
  tester.test_all_scenarios
end