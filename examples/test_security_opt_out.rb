#!/usr/bin/env ruby
# frozen_string_literal: true

# Security Opt-Out Test
# Verifies that browser automation works with and without security

require_relative "../lib/vector_mcp"
require "net/http"
require "json"
require "uri"

class SecurityOptOutTest
  def test_both_scenarios
    puts "🔒🔓 Testing Browser Automation: Security ON vs Security OFF"
    puts "=" * 70

    test_without_security
    puts
    test_with_security
    puts

    print_comparison
  end

  private

  def test_without_security
    puts "🔓 Test 1: Browser Automation WITHOUT Security"
    puts "-" * 50

    # Create server without enabling security
    server = VectorMCP::Server.new("test-no-security", version: "1.0.0")
    server.register_browser_tools

    # Check security status
    puts "Security Status:"
    puts "  Authentication: #{server.auth_manager.required? ? "ENABLED" : "DISABLED"}"
    puts "  Authorization: #{server.authorization.required? ? "ENABLED" : "DISABLED"}"
    puts "  Overall Security: #{server.security_enabled? ? "ENABLED" : "DISABLED"}"

    # Test browser tools registration
    browser_tools = server.tools.keys.select { |name| name.start_with?("browser_") }
    puts "  Browser Tools: #{browser_tools.length} registered"
    puts "    #{browser_tools.join(", ")}"

    if server.security_enabled?
      puts "❌ FAIL: Security should be DISABLED but it's enabled!"
    else
      puts "✅ PASS: Security is properly DISABLED"
    end

    @no_security_result = {
      auth_enabled: server.auth_manager.required?,
      authz_enabled: server.authorization.required?,
      security_enabled: server.security_enabled?,
      tools_count: browser_tools.length
    }
  end

  def test_with_security
    puts "🔒 Test 2: Browser Automation WITH Security"
    puts "-" * 50

    # Create server with security enabled
    server = VectorMCP::Server.new("test-with-security", version: "1.0.0")

    # Enable authentication
    server.enable_authentication!(strategy: :api_key, keys: ["test-key-123"])

    # Enable authorization
    server.enable_authorization! do
      authorize_tools do |user, _action, tool|
        tool.name.start_with?("browser_") ? user[:role] == "browser_user" : true
      end
    end

    # Register browser tools AFTER enabling security
    server.register_browser_tools

    # Check security status
    puts "Security Status:"
    puts "  Authentication: #{server.auth_manager.required? ? "ENABLED" : "DISABLED"}"
    puts "  Authorization: #{server.authorization.required? ? "ENABLED" : "DISABLED"}"
    puts "  Overall Security: #{server.security_enabled? ? "ENABLED" : "DISABLED"}"

    # Test browser tools registration
    browser_tools = server.tools.keys.select { |name| name.start_with?("browser_") }
    puts "  Browser Tools: #{browser_tools.length} registered"
    puts "    #{browser_tools.join(", ")}"

    if server.security_enabled?
      puts "✅ PASS: Security is properly ENABLED"
    else
      puts "❌ FAIL: Security should be ENABLED but it's disabled!"
    end

    @with_security_result = {
      auth_enabled: server.auth_manager.required?,
      authz_enabled: server.authorization.required?,
      security_enabled: server.security_enabled?,
      tools_count: browser_tools.length
    }
  end

  def print_comparison
    puts "📊 Security Comparison Summary"
    puts "=" * 70

    puts "| Feature                | Without Security | With Security   |"
    puts "|------------------------|------------------|-----------------|"
    puts "| Authentication         | #{format("%-16s",
                                              (@no_security_result[:auth_enabled] ? "ENABLED" : "DISABLED"))} | #{format("%-15s",
                                                                                                                         (@with_security_result[:auth_enabled] ? "ENABLED" : "DISABLED"))} |"
    puts "| Authorization          | #{format("%-16s",
                                              (@no_security_result[:authz_enabled] ? "ENABLED" : "DISABLED"))} | #{format("%-15s",
                                                                                                                          (@with_security_result[:authz_enabled] ? "ENABLED" : "DISABLED"))} |"
    puts "| Overall Security       | #{format("%-16s",
                                              (@no_security_result[:security_enabled] ? "ENABLED" : "DISABLED"))} | #{format("%-15s",
                                                                                                                             (@with_security_result[:security_enabled] ? "ENABLED" : "DISABLED"))} |"
    puts "| Browser Tools Count    | #{"%-16s" % @no_security_result[:tools_count]} | #{"%-15s" % @with_security_result[:tools_count]} |"

    puts
    puts "🔍 Analysis:"

    # Check if tools are available in both scenarios
    if @no_security_result[:tools_count] == @with_security_result[:tools_count] &&
       @no_security_result[:tools_count].positive?
      puts "  ✅ Browser tools are available in BOTH scenarios"
      puts "     → Users can opt out of security and still use browser automation"
    else
      puts "  ❌ Browser tools availability differs between scenarios"
      puts "     → This indicates a problem with security opt-out functionality"
    end

    # Check security states
    if !@no_security_result[:security_enabled] && @with_security_result[:security_enabled]
      puts "  ✅ Security can be properly enabled/disabled"
      puts "     → Security is truly optional"
    else
      puts "  ❌ Security state is not working as expected"
    end

    puts
    puts "🎯 Key Findings:"
    puts "  1. Browser automation works with security DISABLED: #{@no_security_result[:tools_count].positive? ? "✅ YES" : "❌ NO"}"
    puts "  2. Browser automation works with security ENABLED: #{@with_security_result[:tools_count].positive? ? "✅ YES" : "❌ NO"}"
    puts "  3. Security can be opted out: #{@no_security_result[:security_enabled] ? "❌ NO" : "✅ YES"}"
    puts "  4. Same functionality in both modes: #{@no_security_result[:tools_count] == @with_security_result[:tools_count] ? "✅ YES" : "❌ NO"}"

    puts
    if @no_security_result[:tools_count].positive? && !@no_security_result[:security_enabled]
      puts "🎉 SUCCESS: Users CAN opt out of security features while keeping full browser automation!"
    else
      puts "⚠️  ISSUE: Security opt-out may not be working correctly."
    end
  end
end

# Simple HTTP test helper
class SimpleHTTPTest
  def self.test_endpoint_accessibility(url, endpoint)
    uri = URI("#{url}#{endpoint}")
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = { test: true }.to_json

    response = Net::HTTP.start(uri.hostname, uri.port) do |http|
      http.read_timeout = 2
      http.open_timeout = 2
      http.request(request)
    end

    # Return true if endpoint is accessible (not 401/403)
    ![401, 403].include?(response.code.to_i)
  rescue StandardError
    false
  end
end

# Main execution
if __FILE__ == $PROGRAM_NAME
  puts "🔒🔓 VectorMCP Security Opt-Out Test"
  puts
  puts "This test verifies that browser automation works both:"
  puts "  1. WITHOUT security (for development/testing)"
  puts "  2. WITH security (for production)"
  puts

  test = SecurityOptOutTest.new
  test.test_both_scenarios

  puts
  puts "💡 Next Steps:"
  puts "  - Start server without security: ruby examples/simple_browser_server_no_security.rb"
  puts "  - Test no-auth endpoints: ruby examples/test_no_security.rb"
  puts "  - Start server with security: ruby examples/security_logging_demo.rb"
  puts "  - Test auth endpoints: ruby examples/test_security_logging.rb"
end
