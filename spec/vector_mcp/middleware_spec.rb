# frozen_string_literal: true

require "spec_helper"
require "vector_mcp/middleware"

# Test middleware class for specs
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

RSpec.describe VectorMCP::Middleware do
  describe VectorMCP::Middleware::Context do
    let(:context) do
      VectorMCP::Middleware::Context.new(
        operation_type: :tool_call,
        operation_name: "test_tool",
        params: { message: "test" },
        session: nil,
        server: nil,
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

    it "provides context summary" do
      summary = context.to_h
      expect(summary[:operation_type]).to eq(:tool_call)
      expect(summary[:operation_name]).to eq("test_tool")
      expect(summary[:success]).to be true
    end
  end

  describe VectorMCP::Middleware::Hook do
    let(:hook) do
      VectorMCP::Middleware::Hook.new(
        TestMiddleware,
        :before_tool_call,
        priority: 50
      )
    end

    let(:context) do
      VectorMCP::Middleware::Context.new(
        operation_type: :tool_call,
        operation_name: "test_tool",
        params: {},
        session: nil,
        server: nil
      )
    end

    it "initializes with correct attributes" do
      expect(hook.middleware_class).to eq(TestMiddleware)
      expect(hook.hook_type).to eq("before_tool_call")
      expect(hook.priority).to eq(50)
    end

    it "validates hook type" do
      expect do
        VectorMCP::Middleware::Hook.new(TestMiddleware, :invalid_hook)
      end.to raise_error(VectorMCP::Middleware::InvalidHookTypeError)
    end

    it "validates middleware class" do
      expect do
        VectorMCP::Middleware::Hook.new(String, :before_tool_call)
      end.to raise_error(ArgumentError, /must inherit from/)
    end

    it "executes hook method" do
      middleware_instance = TestMiddleware.new
      expect(TestMiddleware).to receive(:new).and_return(middleware_instance)

      hook.execute(context)

      expect(middleware_instance.called_hooks).to include(:before_tool_call)
      expect(context.metadata[:test_middleware]).to eq("before_executed")
    end

    it "handles hook errors gracefully" do
      failing_hook = VectorMCP::Middleware::Hook.new(FailingMiddleware, :before_tool_call)

      # Should not raise error, but log it
      expect { failing_hook.execute(context) }.not_to raise_error
    end

    it "sorts by priority" do
      high_priority_hook = VectorMCP::Middleware::Hook.new(TestMiddleware, :before_tool_call, priority: 10)
      low_priority_hook = VectorMCP::Middleware::Hook.new(TestMiddleware, :before_tool_call, priority: 50)

      expect(high_priority_hook <=> low_priority_hook).to eq(-1)
    end

    context "with conditions" do
      it "respects only_operations condition" do
        conditional_hook = VectorMCP::Middleware::Hook.new(
          TestMiddleware,
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
          TestMiddleware,
          :before_tool_call,
          conditions: { except_operations: ["blocked_tool"] }
        )

        # Should execute for normal operation
        expect(conditional_hook.should_execute?(context)).to be true

        # Should not execute for blocked operation
        context.instance_variable_set(:@operation_name, "blocked_tool")
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
      manager.register(TestMiddleware, %i[before_tool_call after_tool_call])

      stats = manager.stats
      expect(stats[:total_hooks]).to eq(2)
      expect(stats[:hook_types]).to include("before_tool_call", "after_tool_call")
    end

    it "executes hooks in priority order" do
      # Register multiple middleware with different priorities
      manager.register(LowPriorityMiddleware, :before_tool_call, priority: 50)
      manager.register(HighPriorityMiddleware, :before_tool_call, priority: 10)

      result_context = manager.execute_hooks(:before_tool_call, context)

      # High priority should execute first
      expect(result_context.metadata[:execution_order]).to eq(%i[high_priority low_priority])
    end

    it "stops execution when skip_remaining_hooks is set" do
      manager.register(SkippingMiddleware, :before_tool_call, priority: 10)
      manager.register(TestMiddleware, :before_tool_call, priority: 20)

      result_context = manager.execute_hooks(:before_tool_call, context)

      expect(result_context.metadata[:first_executed]).to be true
      expect(result_context.metadata[:test_middleware]).to be_nil
    end

    it "unregisters middleware" do
      manager.register(TestMiddleware, :before_tool_call)
      expect(manager.stats[:total_hooks]).to eq(1)

      manager.unregister(TestMiddleware)
      expect(manager.stats[:total_hooks]).to eq(0)
    end

    it "clears all hooks" do
      manager.register(TestMiddleware, %i[before_tool_call after_tool_call])
      expect(manager.stats[:total_hooks]).to eq(2)

      manager.clear!
      expect(manager.stats[:total_hooks]).to eq(0)
    end

    it "provides execution timing metadata" do
      manager.register(TestMiddleware, :before_tool_call)

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
      expect(middleware.class.protected_instance_methods).to include(:skip_remaining_hooks)
    end
  end
end
