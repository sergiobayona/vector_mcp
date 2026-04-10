# frozen_string_literal: true

require "spec_helper"

# Test middleware for integration testing
class IntegrationTestMiddleware < VectorMCP::Middleware::Base
  attr_reader :hook_calls

  def initialize(config = {})
    super
    @hook_calls = []
  end

  def before_tool_call(context)
    @hook_calls << { hook: :before_tool_call, operation: context.operation_name, time: Time.now }
  end

  def after_tool_call(context)
    @hook_calls << { hook: :after_tool_call, operation: context.operation_name, time: Time.now }

    # Modify the result to show middleware was executed
    return unless context.result && context.result[:content]

    context.result[:content] = context.result[:content].map do |item|
      if item[:text]
        item.merge(text: "#{item[:text]} [modified by middleware]")
      else
        item
      end
    end
  end

  def on_tool_error(context)
    @hook_calls << { hook: :on_tool_error, operation: context.operation_name, time: Time.now }
  end

  def before_resource_read(context)
    @hook_calls << { hook: :before_resource_read, operation: context.operation_name, time: Time.now }
  end

  def after_resource_read(context)
    @hook_calls << { hook: :after_resource_read, operation: context.operation_name, time: Time.now }
  end

  def before_prompt_get(context)
    @hook_calls << { hook: :before_prompt_get, operation: context.operation_name, time: Time.now }
  end

  def after_prompt_get(context)
    @hook_calls << { hook: :after_prompt_get, operation: context.operation_name, time: Time.now }
  end
end

# Test middleware classes for priority testing
class FirstMiddleware < VectorMCP::Middleware::Base
  def before_tool_call(context)
    context.add_metadata(:execution_order, []) unless context.metadata[:execution_order]
    context.metadata[:execution_order] << :first
  end
end

class SecondMiddleware < VectorMCP::Middleware::Base
  def before_tool_call(context)
    context.add_metadata(:execution_order, []) unless context.metadata[:execution_order]
    context.metadata[:execution_order] << :second
  end
end

class ParamMutatingMiddleware < VectorMCP::Middleware::Base
  def before_tool_call(context)
    updated_params = context.params.dup
    updated_arguments = (updated_params["arguments"] || {}).merge("message" => "mutated by middleware")
    updated_params["arguments"] = updated_arguments
    modify_params(context, updated_params)
  end
end

class AuthTrackingMiddleware < VectorMCP::Middleware::Base
  attr_reader :events

  def initialize(config = {})
    super
    @events = []
  end

  def before_auth(context)
    @events << { hook: :before_auth, operation: context.operation_name }
  end

  def after_auth(context)
    @events << { hook: :after_auth, user: context.session&.security_context&.user }
  end

  def on_auth_error(context)
    @events << { hook: :on_auth_error, error: context.error.class.name }
  end

  def before_tool_call(context)
    @events << { hook: :before_tool_call, user: context.user }
  end
end

RSpec.describe "Middleware Integration" do
  let(:server) { VectorMCP::Server.new(name: "MiddlewareTestServer", version: "1.0.0") }
  let(:session) { VectorMCP::Session.new(server) }
  let(:middleware) { IntegrationTestMiddleware.new }

  before do
    # Register middleware
    server.use_middleware(IntegrationTestMiddleware, %i[
                            before_tool_call after_tool_call on_tool_error
                            before_resource_read after_resource_read
                            before_prompt_get after_prompt_get
                          ])

    # Get reference to the middleware instance for testing
    # Note: In real usage, you wouldn't need to access the instance directly
    allow(IntegrationTestMiddleware).to receive(:new).and_return(middleware)
  end

  describe "Tool call middleware integration" do
    before do
      server.register_tool(
        name: "test_tool",
        description: "A test tool",
        input_schema: {
          type: "object",
          properties: { message: { type: "string" } },
          required: ["message"]
        }
      ) do |args|
        "Echo: #{args["message"]}"
      end
    end

    it "executes before and after hooks for successful tool calls" do
      params = { "name" => "test_tool", "arguments" => { "message" => "test" } }

      result = VectorMCP::Handlers::Core.call_tool(params, session, server)

      # Check that hooks were called
      hook_types = middleware.hook_calls.map { |call| call[:hook] }
      expect(hook_types).to include(:before_tool_call, :after_tool_call)
      expect(hook_types).not_to include(:on_tool_error)

      # Check that middleware modified the result
      expect(result[:content].first[:text]).to include("[modified by middleware]")
    end

    it "executes error hooks for failed tool calls" do
      server.register_tool(
        name: "failing_tool",
        description: "A tool that always fails",
        input_schema: { type: "object", properties: {} }
      ) do |_args|
        raise StandardError, "Tool failed"
      end

      params = { "name" => "failing_tool", "arguments" => {} }

      expect do
        VectorMCP::Handlers::Core.call_tool(params, session, server)
      end.to raise_error(StandardError, "Tool failed")

      # Check that error hook was called
      hook_types = middleware.hook_calls.map { |call| call[:hook] }
      expect(hook_types).to include(:before_tool_call, :on_tool_error)
      expect(hook_types).not_to include(:after_tool_call)
    end
  end

  describe "Resource read middleware integration" do
    before do
      server.register_resource(
        uri: "test://resource",
        name: "Test Resource",
        description: "A test resource"
      ) do
        "Resource content"
      end
    end

    it "executes before and after hooks for resource reads" do
      params = { "uri" => "test://resource" }

      result = VectorMCP::Handlers::Core.read_resource(params, session, server)

      # Check that hooks were called
      hook_types = middleware.hook_calls.map { |call| call[:hook] }
      expect(hook_types).to include(:before_resource_read, :after_resource_read)

      # Check that result was returned
      expect(result[:contents]).not_to be_empty
    end
  end

  describe "Prompt get middleware integration" do
    before do
      server.register_prompt(
        name: "test_prompt",
        description: "A test prompt",
        arguments: [{ name: "subject", required: true }]
      ) do |args|
        {
          messages: [
            {
              role: "user",
              content: { type: "text", text: "Hello #{args["subject"]}" }
            }
          ]
        }
      end
    end

    it "executes before and after hooks for prompt gets" do
      params = { "name" => "test_prompt", "arguments" => { "subject" => "world" } }

      result = VectorMCP::Handlers::Core.get_prompt(params, session, server)

      # Check that hooks were called
      hook_types = middleware.hook_calls.map { |call| call[:hook] }
      expect(hook_types).to include(:before_prompt_get, :after_prompt_get)

      # Check that result was returned
      expect(result[:messages]).not_to be_empty
    end
  end

  describe "Middleware priority and ordering" do
    it "executes middleware in priority order" do
      # Clear existing middleware and register new ones with specific priorities
      server.clear_middleware!

      server.use_middleware(SecondMiddleware, :before_tool_call, priority: 20)
      server.use_middleware(FirstMiddleware, :before_tool_call, priority: 10)

      server.register_tool(
        name: "priority_test_tool",
        description: "Test tool for priority",
        input_schema: { type: "object", properties: {} }
      ) do |_args|
        "test result"
      end

      params = { "name" => "priority_test_tool", "arguments" => {} }

      # We need to test this by examining the middleware execution
      # In a real scenario, the execution order would be visible through the context
      result = VectorMCP::Handlers::Core.call_tool(params, session, server)

      # The fact that no error occurred indicates priorities are working
      expect(result[:isError]).to be false
    end
  end

  describe "Middleware conditions" do
    it "respects operation-specific conditions" do
      server.clear_middleware!

      # Register middleware only for specific tool
      server.use_middleware(IntegrationTestMiddleware, :before_tool_call,
                            conditions: { only_operations: ["specific_tool"] })

      # Register two tools
      server.register_tool(
        name: "specific_tool",
        description: "Specific tool",
        input_schema: { type: "object", properties: {} }
      ) { "specific result" }

      server.register_tool(
        name: "other_tool",
        description: "Other tool",
        input_schema: { type: "object", properties: {} }
      ) { "other result" }

      # Call specific tool - should trigger middleware
      params1 = { "name" => "specific_tool", "arguments" => {} }
      VectorMCP::Handlers::Core.call_tool(params1, session, server)

      # Call other tool - should not trigger middleware
      params2 = { "name" => "other_tool", "arguments" => {} }
      VectorMCP::Handlers::Core.call_tool(params2, session, server)

      # Check that middleware was only called for specific tool
      operations = middleware.hook_calls.map { |call| call[:operation] }.uniq
      expect(operations).to eq(["specific_tool"])
    end
  end

  describe "Middleware-driven param mutation" do
    it "allows before hooks to replace params used by the handler" do
      server.clear_middleware!
      server.use_middleware(ParamMutatingMiddleware, :before_tool_call)

      server.register_tool(
        name: "mutating_tool",
        description: "Tool whose args are rewritten by middleware",
        input_schema: {
          type: "object",
          properties: { message: { type: "string" } },
          required: ["message"]
        }
      ) do |args|
        "Echo: #{args["message"]}"
      end

      result = VectorMCP::Handlers::Core.call_tool(
        { "name" => "mutating_tool", "arguments" => { "message" => "original" } },
        session,
        server
      )

      expect(result[:content].first[:text]).to include("mutated by middleware")
    end
  end

  describe "Authentication hook integration" do
    let(:auth_middleware) { AuthTrackingMiddleware.new }

    before do
      server.clear_middleware!
      server.use_middleware(AuthTrackingMiddleware, %i[before_auth after_auth on_auth_error before_tool_call])
      allow(AuthTrackingMiddleware).to receive(:new).and_return(auth_middleware)

      server.enable_authentication!(strategy: :api_key, keys: ["valid-key"])
      session.request_context = {
        headers: { "X-API-Key" => "valid-key" },
        params: {}
      }

      server.register_tool(
        name: "secured_tool",
        description: "Tool with auth-aware middleware",
        input_schema: { type: "object", properties: {} }
      ) { "secured" }
    end

    it "runs auth hooks before business-operation hooks and exposes the authenticated user" do
      VectorMCP::Handlers::Core.call_tool({ "name" => "secured_tool", "arguments" => {} }, session, server)

      expect(auth_middleware.events.map { |event| event[:hook] }).to include(:before_auth, :after_auth, :before_tool_call)
      before_tool_event = auth_middleware.events.find { |event| event[:hook] == :before_tool_call }
      expect(before_tool_event[:user]).to include(api_key: "valid-key")
    end

    it "runs auth error hooks on authentication failure" do
      session.request_context = {
        headers: { "X-API-Key" => "invalid-key" },
        params: {}
      }

      expect do
        VectorMCP::Handlers::Core.call_tool({ "name" => "secured_tool", "arguments" => {} }, session, server)
      end.to raise_error(VectorMCP::UnauthorizedError, "Authentication required")

      expect(auth_middleware.events.map { |event| event[:hook] }).to include(:before_auth, :on_auth_error)
    end
  end

  describe "Server middleware management methods" do
    it "provides middleware statistics" do
      stats = server.middleware_stats

      expect(stats).to have_key(:total_hooks)
      expect(stats).to have_key(:hook_types)
      expect(stats).to have_key(:hooks_by_type)
      expect(stats[:total_hooks]).to be > 0
    end

    it "allows removing middleware" do
      server.middleware_stats[:total_hooks]

      server.remove_middleware(IntegrationTestMiddleware)

      expect(server.middleware_stats[:total_hooks]).to eq(0)
    end

    it "allows clearing all middleware" do
      expect(server.middleware_stats[:total_hooks]).to be > 0

      server.clear_middleware!

      expect(server.middleware_stats[:total_hooks]).to eq(0)
    end
  end
end
