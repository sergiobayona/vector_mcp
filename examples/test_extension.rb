#!/usr/bin/env ruby
# frozen_string_literal: true

# Simple test script to verify Chrome extension is working
require "net/http"
require "json"
require "uri"

puts "🧪 Testing VectorMCP Chrome Extension Connection"
puts "=" * 50

def test_endpoint(method, path, data = nil)
  uri = URI("http://localhost:8000#{path}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.open_timeout = 5
  http.read_timeout = 35  # Browser operations can take time
  
  case method.upcase
  when "GET"
    request = Net::HTTP::Get.new(uri)
  when "POST"
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = data.to_json if data
  end
  
  puts "#{method.upcase} #{path}"
  puts "  Data: #{data.inspect}" if data
  
  start_time = Time.now
  response = http.request(request)
  duration = Time.now - start_time
  
  puts "  Response: #{response.code} (#{duration.round(2)}s)"
  
  if response.body && !response.body.empty?
    begin
      result = JSON.parse(response.body)
      puts "  Body: #{result.inspect}"
      result
    rescue JSON::ParserError
      puts "  Body: #{response.body}"
      response.body
    end
  else
    puts "  Body: (empty)"
    nil
  end
rescue StandardError => e
  puts "  ERROR: #{e.message}"
  nil
ensure
  puts ""
end

# Test 1: Server health check
puts "1️⃣ Testing server health..."
result = test_endpoint("GET", "/")

unless result
  puts "❌ Server not responding. Make sure to run:"
  puts "   ruby examples/browser_server.rb"
  exit 1
end

# Test 2: Browser ping (extension registration)
puts "2️⃣ Testing extension ping..."
result = test_endpoint("POST", "/browser/ping", { test: true })

# Test 3: Browser poll (check for commands)
puts "3️⃣ Testing command polling..."
result = test_endpoint("GET", "/browser/poll")

# Test 4: Simple wait command (should work without browser)
puts "4️⃣ Testing wait command..."
result = test_endpoint("POST", "/browser/wait", { duration: 1000 })

# Test 5: Navigation command (requires extension)
puts "5️⃣ Testing navigation command..."
result = test_endpoint("POST", "/browser/navigate", { 
  url: "https://www.google.com", 
  include_snapshot: false 
})

if result && result["success"]
  puts "✅ Navigation succeeded! Extension is working."
elsif result && result["error"] == "Chrome extension not connected"
  puts "⚠️  Extension not connected. Check Chrome extension:"
  puts "   1. Extension installed and enabled?"
  puts "   2. Extension permissions granted?"
  puts "   3. Check Chrome console (F12) for errors"
  puts "   4. Try reloading the extension"
elsif result && result["error"] == "Command timed out"
  puts "⚠️  Command timed out. Extension may not be polling:"
  puts "   1. Check Chrome console (F12) for errors"
  puts "   2. Try reloading the extension page"
  puts "   3. Ensure no JavaScript errors in background script"
else
  puts "❌ Unexpected error: #{result.inspect}"
end

puts ""
puts "🔍 Troubleshooting Tips:"
puts "• Check Chrome Extensions page: chrome://extensions/"
puts "• Look for 'VectorMCP Browser Automation' extension"
puts "• Click extension icon to see connection status"
puts "• Check browser console (F12) for JavaScript errors"
puts "• Try reloading the extension or restarting Chrome"