# frozen_string_literal: true

require "spec_helper"
require "vector_mcp/middleware"

# Test middleware class for specs
module MiddlewareSpecSupport
  class TestMiddleware < VectorMCP::Middleware::Base
    attr_reader :called_hooks

    def initialize(config = {})
      super
      @called_hooks = []
    end

    def before_tool_call(context)
      @called_hooks << :before_tool_call
      context.add_metadata(:test_middleware, "before_executed")
    end

    def after_tool_call(context)
      @called_hooks << :after_tool_call
      context.add_metadata(:test_middleware, "after_executed")
    end

    def on_tool_error(context)
      @called_hooks << :on_tool_error
      # Simulate error handling
      context.result = {
        isError: false,
        content: [{ type: "text", text: "Error handled by middleware" }]
      }
    end
  end

  # Failing middleware for error testing
  class FailingMiddleware < VectorMCP::Middleware::Base
    def before_tool_call(_context)
      raise StandardError, "Middleware failed"
    end
  end

  # High priority middleware for priority testing
  class HighPriorityMiddleware < VectorMCP::Middleware::Base
    def before_tool_call(context)
      context.add_metadata(:execution_order, []) unless context.metadata[:execution_order]
      context.metadata[:execution_order] << :high_priority
    end
  end

  # Low priority middleware for priority testing
  class LowPriorityMiddleware < VectorMCP::Middleware::Base
    def before_tool_call(context)
      context.add_metadata(:execution_order, []) unless context.metadata[:execution_order]
      context.metadata[:execution_order] << :low_priority
    end
  end

  # Skipping middleware for flow control testing
  class SkippingMiddleware < VectorMCP::Middleware::Base
    def before_tool_call(context)
      context.add_metadata(:first_executed, true)
      context.skip_remaining_hooks = true
    end
  end
end

RSpec.describe VectorMCP::Middleware do
  describe VectorMCP::Middleware::Context do
    let(:server) { instance_double(VectorMCP::Server, logger: VectorMCP.logger_for("spec")) }
    let(:session) { VectorMCP::Session.new(server, nil, id: "middleware-session") }
    let(:context) do
      VectorMCP::Middleware::Context.new(
        operation_type: :tool_call,
        operation_name: "test_tool",
        params: { message: "test" },
        session: session,
        server: server,
        metadata: { test: "data" }
      )
    end

    it "initializes with correct attributes" do
      expect(context.operation_type).to eq(:tool_call)
      expect(context.operation_name).to eq("test_tool")
      expect(context.params).to eq({ message: "test" })
      expect(context.metadata[:test]).to eq("data")
    end

    it "tracks success/error state" do
      expect(context.success?).to be true
      expect(context.error?).to be false

      context.error = StandardError.new("test error")
      expect(context.success?).to be false
      expect(context.error?).to be true
    end

    it "allows adding metadata" do
      context.add_metadata(:new_key, "new_value")
      expect(context.metadata[:new_key]).to eq("new_value")
    end

    it "allows replacing params" do
      context.params = { message: "changed" }
      expect(context.params).to eq({ message: "changed" })
    end

    it "raises ArgumentError when params is set to a non-Hash" do
      expect { context.params = "invalid" }.to raise_error(ArgumentError, /params must be a Hash/)
      expect { context.params = 42 }.to raise_error(ArgumentError, /params must be a Hash/)
    end

    it "normalizes nil params to an empty hash" do
      context.params = nil
      expect(context.params).to eq({})
    end

    it "duplicates the hash so caller mutations do not leak" do
      original = { "key" => "value" }
      context.params = original
      original["key"] = "mutated"
      expect(context.params["key"]).to eq("value")
    end

    it "exposes the authenticated user from the session security context" do
      session.security_context = VectorMCP::Security::SessionContext.new(
        user: { user_id: "user-123" },
        authenticated: true
      )

      expect(context.user).to eq({ user_id: "user-123" })
    end

    it "provides context summary" do
      summary = context.to_h
      expect(summary[:operation_type]).to eq(:tool_call)
      expect(summary[:operation_name]).to eq("test_tool")
      expect(summary[:success]).to be true
    end
  end

  describe VectorMCP::Middleware::Hook do
    let(:server) { instance_double(VectorMCP::Server, logger: VectorMCP.logger_for("spec")) }
    let(:session) { VectorMCP::Session.new(server, nil, id: "hook-session") }
    let(:hook) do
      VectorMCP::Middleware::Hook.new(
        MiddlewareSpecSupport::TestMiddleware,
        :before_tool_call,
        priority: 50
      )
    end

    let(:context) do
      VectorMCP::Middleware::Context.new(
        operation_type: :tool_call,
        operation_name: "test_tool",
        params: {},
        session: session,
        server: server
      )
    end

    it "initializes with correct attributes" do
      expect(hook.middleware_class).to eq(MiddlewareSpecSupport::TestMiddleware)
      expect(hook.hook_type).to eq("before_tool_call")
      expect(hook.priority).to eq(50)
    end

    it "validates hook type" do
      expect do
        VectorMCP::Middleware::Hook.new(MiddlewareSpecSupport::TestMiddleware, :invalid_hook)
      end.to raise_error(VectorMCP::Middleware::InvalidHookTypeError)
    end

    it "validates middleware class" do
      expect do
        VectorMCP::Middleware::Hook.new(String, :before_tool_call)
      end.to raise_error(ArgumentError, /must inherit from/)
    end

    it "executes hook method" do
      middleware_instance = MiddlewareSpecSupport::TestMiddleware.new
      expect(MiddlewareSpecSupport::TestMiddleware).to receive(:new).and_return(middleware_instance)

      hook.execute(context)

      expect(middleware_instance.called_hooks).to include(:before_tool_call)
      expect(context.metadata[:test_middleware]).to eq("before_executed")
    end

    it "handles hook errors gracefully" do
      failing_hook = VectorMCP::Middleware::Hook.new(MiddlewareSpecSupport::FailingMiddleware, :before_tool_call)

      # Should not raise error, but log it
      expect { failing_hook.execute(context) }.not_to raise_error
    end

    it "sorts by priority" do
      high_priority_hook = VectorMCP::Middleware::Hook.new(MiddlewareSpecSupport::TestMiddleware, :before_tool_call, priority: 10)
      low_priority_hook = VectorMCP::Middleware::Hook.new(MiddlewareSpecSupport::TestMiddleware, :before_tool_call, priority: 50)

      expect(high_priority_hook <=> low_priority_hook).to eq(-1)
    end

    context "with conditions" do
      it "respects only_operations condition" do
        conditional_hook = VectorMCP::Middleware::Hook.new(
          MiddlewareSpecSupport::TestMiddleware,
          :before_tool_call,
          conditions: { only_operations: ["allowed_tool"] }
        )

        # Should not execute for wrong operation
        expect(conditional_hook.should_execute?(context)).to be false

        # Should execute for correct operation
        context.instance_variable_set(:@operation_name, "allowed_tool")
        expect(conditional_hook.should_execute?(context)).to be true
      end

      it "respects except_operations condition" do
        conditional_hook = VectorMCP::Middleware::Hook.new(
          MiddlewareSpecSupport::TestMiddleware,
          :before_tool_call,
          conditions: { except_operations: ["blocked_tool"] }
        )

        # Should execute for normal operation
        expect(conditional_hook.should_execute?(context)).to be true

        # Should not execute for blocked operation
        context.instance_variable_set(:@operation_name, "blocked_tool")
        expect(conditional_hook.should_execute?(context)).to be false
      end

      it "respects only_users condition" do
        context.session.security_context = VectorMCP::Security::SessionContext.new(
          user: { user_id: "user-123" },
          authenticated: true
        )

        conditional_hook = VectorMCP::Middleware::Hook.new(
          MiddlewareSpecSupport::TestMiddleware,
          :before_tool_call,
          conditions: { only_users: ["user-123"] }
        )

        expect(conditional_hook.should_execute?(context)).to be true

        context.session.security_context = VectorMCP::Security::SessionContext.new(
          user: { user_id: "other-user" },
          authenticated: true
        )
        expect(conditional_hook.should_execute?(context)).to be false
      end
    end
  end

  describe VectorMCP::Middleware::Manager do
    let(:manager) { VectorMCP::Middleware::Manager.new }
    let(:context) do
      VectorMCP::Middleware::Context.new(
        operation_type: :tool_call,
        operation_name: "test_tool",
        params: {},
        session: nil,
        server: nil
      )
    end

    it "registers middleware for hooks" do
      manager.register(MiddlewareSpecSupport::TestMiddleware, %i[before_tool_call after_tool_call])

      stats = manager.stats
      expect(stats[:total_hooks]).to eq(2)
      expect(stats[:hook_types]).to include("before_tool_call", "after_tool_call")
    end

    it "executes hooks in priority order" do
      # Register multiple middleware with different priorities
      manager.register(MiddlewareSpecSupport::LowPriorityMiddleware, :before_tool_call, priority: 50)
      manager.register(MiddlewareSpecSupport::HighPriorityMiddleware, :before_tool_call, priority: 10)

      result_context = manager.execute_hooks(:before_tool_call, context)

      # High priority should execute first
      expect(result_context.metadata[:execution_order]).to eq(%i[high_priority low_priority])
    end

    it "stops execution when skip_remaining_hooks is set" do
      manager.register(MiddlewareSpecSupport::SkippingMiddleware, :before_tool_call, priority: 10)
      manager.register(MiddlewareSpecSupport::TestMiddleware, :before_tool_call, priority: 20)

      result_context = manager.execute_hooks(:before_tool_call, context)

      expect(result_context.metadata[:first_executed]).to be true
      expect(result_context.metadata[:test_middleware]).to be_nil
    end

    it "unregisters middleware" do
      manager.register(MiddlewareSpecSupport::TestMiddleware, :before_tool_call)
      expect(manager.stats[:total_hooks]).to eq(1)

      manager.unregister(MiddlewareSpecSupport::TestMiddleware)
      expect(manager.stats[:total_hooks]).to eq(0)
    end

    it "clears all hooks" do
      manager.register(MiddlewareSpecSupport::TestMiddleware, %i[before_tool_call after_tool_call])
      expect(manager.stats[:total_hooks]).to eq(2)

      manager.clear!
      expect(manager.stats[:total_hooks]).to eq(0)
    end

    it "provides execution timing metadata" do
      manager.register(MiddlewareSpecSupport::TestMiddleware, :before_tool_call)

      result_context = manager.execute_hooks(:before_tool_call, context)

      timing = result_context.metadata[:middleware_timing]
      expect(timing).to be_a(Hash)
      expect(timing[:hook_type]).to eq("before_tool_call")
      expect(timing[:execution_time]).to be_a(Numeric)
      expect(timing[:hooks_executed]).to eq(1)
    end
  end

  describe VectorMCP::Middleware::Base do
    let(:middleware) { VectorMCP::Middleware::Base.new }
    let(:context) do
      VectorMCP::Middleware::Context.new(
        operation_type: :tool_call,
        operation_name: "test_tool",
        params: {},
        session: nil,
        server: nil
      )
    end

    it "initializes with configuration" do
      config = { test: "value" }
      middleware = VectorMCP::Middleware::Base.new(config)

      expect(middleware.send(:config)).to eq(config)
    end

    it "provides default hook implementations" do
      # Should not raise errors for any hook type
      expect { middleware.before_tool_call(context) }.not_to raise_error
      expect { middleware.after_tool_call(context) }.not_to raise_error
      expect { middleware.on_tool_error(context) }.not_to raise_error
    end

    it "responds to generic call method" do
      expect { middleware.call("before_tool_call", context) }.not_to raise_error
    end

    it "provides helper methods" do
      # Test helper methods exist (they are protected methods)
      expect(middleware.class.protected_instance_methods).to include(:modify_result)
      expect(middleware.class.protected_instance_methods).to include(:modify_params)
      expect(middleware.class.protected_instance_methods).to include(:skip_remaining_hooks)
    end

    it "can modify params through the helper" do
      middleware.send(:modify_params, context, { changed: true })
      expect(context.params).to eq({ changed: true })
    end
  end
end
