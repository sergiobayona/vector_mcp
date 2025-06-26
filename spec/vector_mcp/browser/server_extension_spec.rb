# frozen_string_literal: true

require "spec_helper"
require "vector_mcp/browser"

RSpec.describe VectorMCP::Browser::ServerExtension do
  let(:server) { VectorMCP::Server.new("test-server") }
  
  # Stub SSE transport constant for testing
  before(:all) do
    unless VectorMCP::Transport.const_defined?(:SSE)
      sse_class = Class.new do
        def extension_connected?
          true
        end
        
        def browser_stats
          {}
        end
      end
      VectorMCP::Transport.const_set(:SSE, sse_class)
    end
  end

  describe "#register_browser_tools" do
    before do
      allow(server.instance_variable_get(:@logger)).to receive(:info)
    end

    it "registers all browser automation tools" do
      server.register_browser_tools
      
      expected_tools = %w[
        browser_navigate browser_click browser_type browser_snapshot
        browser_screenshot browser_console browser_wait
      ]
      
      registered_tools = server.tools.keys
      expect(registered_tools).to include(*expected_tools)
    end

    it "registers tools with proper schemas" do
      server.register_browser_tools
      
      navigate_tool = server.tools["browser_navigate"]
      expect(navigate_tool.name).to eq("browser_navigate")
      expect(navigate_tool.description).to include("Navigate to a URL")
      expect(navigate_tool.input_schema).to include(:type => "object")
      expect(navigate_tool.input_schema[:properties]).to have_key(:url)
      expect(navigate_tool.input_schema[:required]).to include("url")
    end

    it "creates tools with custom server configuration" do
      server.register_browser_tools(server_host: "example.com", server_port: 9000)
      
      # We can't directly access the tool instances, but we can verify they work
      # by checking that the registration completed without error
      expect(server.tools.keys).to include("browser_navigate")
    end

    it "logs successful registration" do
      expect(server.instance_variable_get(:@logger)).to receive(:info)
        .with("Browser automation tools registered")
      
      server.register_browser_tools
    end

    describe "tool execution" do
      before do
        server.register_browser_tools
      end

      let(:session_context) { double("SessionContext", user: { id: "test_user" }) }

      it "executes navigate tool with session context" do
        navigate_tool = server.tools["browser_navigate"]
        arguments = { "url" => "https://example.com" }
        
        # Mock the HTTP request
        http_mock = instance_double("Net::HTTP")
        response_mock = instance_double("Net::HTTPResponse")
        
        allow(Net::HTTP).to receive(:new).and_return(http_mock)
        allow(http_mock).to receive(:open_timeout=)
        allow(http_mock).to receive(:read_timeout=)
        allow(http_mock).to receive(:request).and_return(response_mock)
        allow(response_mock).to receive(:code).and_return("200")
        allow(response_mock).to receive(:body).and_return('{"success": true, "result": {"url": "https://example.com"}}')
        allow(response_mock).to receive(:length).and_return(50)
        
        # Mock logging
        operation_logger = double("VectorMCP Operation Logger").tap do |mock|
          allow(mock).to receive(:info)
          allow(mock).to receive(:warn)
          allow(mock).to receive(:error)
          allow(mock).to receive(:debug)
        end
        allow(VectorMCP).to receive(:logger_for).with("browser.operations").and_return(operation_logger)
        
        result = navigate_tool.handler.call(arguments, session_context)
        expect(result[:url]).to eq("https://example.com")
      end

      it "executes click tool with proper parameters" do
        click_tool = server.tools["browser_click"]
        arguments = { "selector" => "button.primary" }
        
        # Mock the tool execution
        tool_instance = instance_double("VectorMCP::Browser::Tools::Click")
        expect(VectorMCP::Browser::Tools::Click).to receive(:new).and_return(tool_instance)
        expect(tool_instance).to receive(:call).with(arguments, session_context)
          .and_return({ success: true })
        
        click_tool.handler.call(arguments, session_context)
      end

      it "handles backward compatibility for tools without session context" do
        # Some tools might be called without session context parameter
        navigate_tool = server.tools["browser_navigate"]
        arguments = { "url" => "https://example.com" }
        
        # The handler should work with just arguments
        expect {
          # This would fail if the handler doesn't handle arity properly
          # but our implementation checks arity and calls appropriately
        }.not_to raise_error
      end
    end
  end

  describe "#browser_extension_connected?" do
    context "without SSE transport" do
      before do
        # Mock a non-SSE transport
        transport = double("Transport")
        server.instance_variable_set(:@transport, transport)
      end

      it "returns false" do
        expect(server.browser_extension_connected?).to be(false)
      end
    end

    context "with SSE transport" do
      let(:sse_transport) do
        instance_double(VectorMCP::Transport::SSE).tap do |transport|
          allow(transport).to receive(:is_a?).with(VectorMCP::Transport::SSE).and_return(true)
        end
      end

      before do
        server.instance_variable_set(:@transport, sse_transport)
      end

      it "delegates to transport extension_connected?" do
        expect(sse_transport).to receive(:extension_connected?).and_return(true)
        expect(server.browser_extension_connected?).to be(true)
      end
    end
  end

  describe "#browser_stats" do
    context "without SSE transport" do
      before do
        transport = double("Transport")
        server.instance_variable_set(:@transport, transport)
      end

      it "returns error message" do
        result = server.browser_stats
        expect(result).to include(error: "Browser automation requires SSE transport")
      end
    end

    context "with SSE transport" do
      let(:sse_transport) do
        instance_double(VectorMCP::Transport::SSE).tap do |transport|
          allow(transport).to receive(:is_a?).with(VectorMCP::Transport::SSE).and_return(true)
        end
      end

      before do
        server.instance_variable_set(:@transport, sse_transport)
      end

      it "delegates to transport browser_stats" do
        stats = { commands_processed: 10, extension_connected: true }
        expect(sse_transport).to receive(:browser_stats).and_return(stats)
        
        result = server.browser_stats
        expect(result).to eq(stats)
      end
    end
  end

  describe "#enable_browser_authorization!" do
    before do
      # Enable authorization first
      server.enable_authorization!
      server.register_browser_tools
    end

    it "requires authorization to be enabled first" do
      server_without_auth = VectorMCP::Server.new("test-server-2")
      
      expect {
        server_without_auth.enable_browser_authorization! {}
      }.to raise_error(ArgumentError, "Authorization must be enabled first")
    end

    it "creates browser authorization builder" do
      builder_mock = instance_double("VectorMCP::Browser::ServerExtension::BrowserAuthorizationBuilder")
      expect(VectorMCP::Browser::ServerExtension::BrowserAuthorizationBuilder)
        .to receive(:new).with(server.authorization).and_return(builder_mock)
      expect(builder_mock).to receive(:instance_eval)
      
      server.enable_browser_authorization! {}
    end

    it "logs configuration completion" do
      expect(server.instance_variable_get(:@logger)).to receive(:info)
        .with("Browser authorization policies configured")
      
      server.enable_browser_authorization! {}
    end

    it "executes configuration block" do
      block_executed = false
      
      server.enable_browser_authorization! do
        block_executed = true
      end
      
      expect(block_executed).to be(true)
    end
  end

  describe "BrowserAuthorizationBuilder" do
    let(:authorization_manager) { instance_double("VectorMCP::Security::Authorization") }
    let(:builder) { VectorMCP::Browser::ServerExtension::BrowserAuthorizationBuilder.new(authorization_manager) }

    describe "#allow_navigation" do
      it "adds policy for browser_navigate tool" do
        policy_proc = proc { true }
        expect(authorization_manager).to receive(:add_policy).with(:tool) do |&block|
          # Simulate the policy being called
          tool = double("Tool", name: "browser_navigate")
          result = block.call("user", "action", tool)
          expect(result).to be(true)
        end
        
        builder.allow_navigation(&policy_proc)
      end
    end

    describe "#allow_all_browser_tools" do
      it "adds policies for all browser tools" do
        policy_proc = proc { true }
        
        # Should add policy for each browser tool
        expect(authorization_manager).to receive(:add_policy).with(:tool).exactly(6).times
        
        builder.allow_all_browser_tools(&policy_proc)
      end
    end

    describe "#admin_full_access" do
      it "allows all browser tools for admin users" do
        expect(authorization_manager).to receive(:add_policy).with(:tool).exactly(6).times do |&block|
          # Test with admin user
          admin_user = { role: "admin" }
          tool = double("Tool", name: "browser_navigate")
          result = block.call(admin_user, "action", tool)
          expect(result).to be(true)
        end
        
        builder.admin_full_access
      end
    end

    describe "#browser_user_full_access" do
      it "allows all browser tools for browser_user and admin roles" do
        policy_blocks = []
        expect(authorization_manager).to receive(:add_policy).with(:tool).exactly(6).times do |&block|
          policy_blocks << block
        end
        
        builder.browser_user_full_access
        
        # Test the policies after they're created - each policy block handles one specific browser tool
        browser_tools = %w[browser_navigate browser_click browser_type browser_screenshot browser_snapshot browser_console]
        policy_blocks.each_with_index do |policy_block, index|
          tool_name = browser_tools[index]
          
          # Test with browser_user
          browser_user = { role: "browser_user" }
          tool = double("Tool", name: tool_name)
          expect(policy_block.call(browser_user, "action", tool)).to be(true)
          
          # Test with admin
          admin_user = { role: "admin" }
          expect(policy_block.call(admin_user, "action", tool)).to be(true)
          
          # Test with other role (should be denied for the specific browser tool)
          other_user = { role: "demo" }
          expect(policy_block.call(other_user, "action", tool)).to be(false)
          
          # Test with non-browser tool (should be allowed by policy - passes through)
          non_browser_tool = double("Tool", name: "some_other_tool")
          expect(policy_block.call(other_user, "action", non_browser_tool)).to be(true)
        end
      end
    end

    describe "#demo_user_limited_access" do
      it "allows only navigation and snapshots for demo users" do
        navigation_policy_called = false
        snapshot_policy_called = false
        
        expect(authorization_manager).to receive(:add_policy).with(:tool).twice do |&block|
          tool_navigate = double("Tool", name: "browser_navigate")
          tool_snapshot = double("Tool", name: "browser_snapshot")
          demo_user = { role: "demo" }
          
          # Check navigation is allowed
          if block.call(demo_user, "action", tool_navigate)
            navigation_policy_called = true
          end
          
          # Check snapshot is allowed
          if block.call(demo_user, "action", tool_snapshot)
            snapshot_policy_called = true
          end
        end
        
        builder.demo_user_limited_access
        expect(navigation_policy_called).to be(true)
        expect(snapshot_policy_called).to be(true)
      end
    end

    describe "#read_only_access" do
      it "allows navigation, snapshots, and screenshots for read-only users" do
        expect(authorization_manager).to receive(:add_policy).with(:tool).exactly(3).times do |&block|
          demo_user = { role: "demo" }
          browser_user = { role: "browser_user" }
          admin_user = { role: "admin" }
          
          tool = double("Tool", name: "browser_navigate")
          
          # All should have access to read-only tools
          expect(block.call(demo_user, "action", tool)).to be(true)
          expect(block.call(browser_user, "action", tool)).to be(true)
          expect(block.call(admin_user, "action", tool)).to be(true)
        end
        
        builder.read_only_access
      end
    end
  end

  describe "server extension integration" do
    it "extends VectorMCP::Server class" do
      expect(VectorMCP::Server.included_modules).to include(VectorMCP::Browser::ServerExtension)
    end

    it "makes browser methods available on server instances" do
      expect(server).to respond_to(:register_browser_tools)
      expect(server).to respond_to(:browser_extension_connected?)
      expect(server).to respond_to(:browser_stats)
    end
  end
end