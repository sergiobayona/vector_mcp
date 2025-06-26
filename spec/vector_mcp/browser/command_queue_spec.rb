# frozen_string_literal: true

require "spec_helper"
require "vector_mcp/browser"

RSpec.describe VectorMCP::Browser::CommandQueue do
  let(:logger) { Logger.new(StringIO.new) }
  let(:mock_queue_logger) do
    double("VectorMCP Queue Logger").tap do |mock|
      allow(mock).to receive(:info)
      allow(mock).to receive(:warn)
      allow(mock).to receive(:error)
      allow(mock).to receive(:debug)
    end
  end
  let(:queue) do
    allow(VectorMCP).to receive(:logger_for).with("browser.queue").and_return(mock_queue_logger)
    described_class.new(logger)
  end

  describe "#initialize" do
    it "initializes with logger" do
      expect(queue.instance_variable_get(:@logger)).to eq(logger)
    end

    it "initializes empty command collections" do
      pending_commands = queue.instance_variable_get(:@pending_commands)
      completed_commands = queue.instance_variable_get(:@completed_commands)
      
      expect(pending_commands).to be_empty
      expect(completed_commands).to be_empty
    end

    it "initializes queue logger" do
      queue_logger = queue.instance_variable_get(:@queue_logger)
      expect(queue_logger).not_to be_nil
    end
  end

  describe "#enqueue_command" do
    let(:command) do
      {
        id: "test-command-123",
        action: "navigate",
        params: { url: "https://example.com" },
        timestamp: Time.now.to_f
      }
    end

    before do
      allow(VectorMCP).to receive(:logger_for).with("browser.queue").and_return(logger)
    end

    it "adds command to pending queue" do
      queue.enqueue_command(command)
      
      pending_commands = queue.instance_variable_get(:@pending_commands)
      expect(pending_commands).to include(command)
    end

    it "logs command enqueuing" do
      expect(logger).to receive(:debug).with(/Enqueued command: test-command-123/)
      expect(mock_queue_logger).to receive(:info).with("Command queued", context: hash_including(:command_id, :action, :queue_size))
      
      queue.enqueue_command(command)
    end

    it "tracks queue size in logs" do
      queue.enqueue_command(command)
      
      another_command = command.merge(id: "test-command-456")
      
      expect(mock_queue_logger).to receive(:info).with("Command queued", context: hash_including(queue_size: 2))
      
      queue.enqueue_command(another_command)
    end
  end

  describe "#get_pending_commands" do
    let(:commands) do
      [
        { id: "cmd-1", action: "navigate", params: {} },
        { id: "cmd-2", action: "click", params: {} }
      ]
    end

    before do
      allow(VectorMCP).to receive(:logger_for).with("browser.queue").and_return(logger)
      commands.each { |cmd| queue.enqueue_command(cmd) }
    end

    it "returns all pending commands" do
      pending_commands = queue.get_pending_commands
      expect(pending_commands).to match_array(commands)
    end

    it "clears pending commands after retrieval" do
      queue.get_pending_commands
      
      pending_commands = queue.instance_variable_get(:@pending_commands)
      expect(pending_commands).to be_empty
    end

    it "logs command dispatch when commands exist" do
      expect(mock_queue_logger).to receive(:info).with("Commands dispatched to extension", 
        context: hash_including(
          command_count: 2,
          command_ids: ["cmd-1", "cmd-2"],
          actions: ["navigate", "click"]
        ))
      
      queue.get_pending_commands
    end

    it "does not log when no commands are pending" do
      queue.get_pending_commands # Clear existing commands
      
      expect(logger).not_to receive(:info).with(/Commands dispatched/)
      
      queue.get_pending_commands
    end

    it "returns empty array when no commands pending" do
      queue.get_pending_commands # Clear existing
      
      result = queue.get_pending_commands
      expect(result).to eq([])
    end
  end

  describe "#complete_command" do
    let(:command_id) { "test-command-123" }
    let(:result_data) { { url: "https://example.com", success: true } }

    before do
      allow(VectorMCP).to receive(:logger_for).with("browser.queue").and_return(logger)
    end

    it "stores completion data" do
      queue.complete_command(command_id, true, result_data, nil)
      
      completed_commands = queue.instance_variable_get(:@completed_commands)
      completion_data = completed_commands[command_id]
      
      expect(completion_data[:success]).to be(true)
      expect(completion_data[:result]).to eq(result_data)
      expect(completion_data[:error]).to be_nil
      expect(completion_data[:completed_at]).to be_a(Float)
    end

    it "logs command completion" do
      expect(logger).to receive(:debug).with(/Completed command: #{command_id}/)
      expect(mock_queue_logger).to receive(:info).with("Command completed by extension", 
        context: hash_including(
          command_id: command_id,
          success: true,
          error: nil
        ))
      
      queue.complete_command(command_id, true, result_data, nil)
    end

    it "logs error information for failed commands" do
      error_message = "Navigation failed"
      
      expect(mock_queue_logger).to receive(:info).with("Command completed by extension",
        context: hash_including(
          command_id: command_id,
          success: false,
          error: error_message
        ))
      
      queue.complete_command(command_id, false, nil, error_message)
    end

    it "calculates result size for logging" do
      large_result = { data: "A" * 1000 }
      
      expect(mock_queue_logger).to receive(:info).with("Command completed by extension",
        context: hash_including(
          result_size: be > 1000
        ))
      
      queue.complete_command(command_id, true, large_result, nil)
    end

    it "signals waiting threads" do
      # Set up a condition for the command
      result_conditions = queue.instance_variable_get(:@result_conditions)
      condition = Concurrent::Event.new
      result_conditions[command_id] = condition
      
      expect(condition).to receive(:set)
      
      queue.complete_command(command_id, true, result_data, nil)
    end
  end

  describe "#wait_for_result" do
    let(:command_id) { "test-command-123" }

    context "when result is already available" do
      let(:completion_data) do
        {
          success: true,
          result: { url: "https://example.com" },
          error: nil,
          completed_at: Time.now.to_f
        }
      end

      before do
        completed_commands = queue.instance_variable_get(:@completed_commands)
        completed_commands[command_id] = completion_data
      end

      it "returns existing result immediately" do
        result = queue.wait_for_result(command_id)
        expect(result).to eq(completion_data)
      end
    end

    context "when result is not yet available" do
      it "waits for result to be completed" do
        # Start waiting in a separate thread
        result_future = Concurrent::Future.execute do
          queue.wait_for_result(command_id, timeout: 1)
        end

        # Give the thread time to start waiting
        sleep(0.1)

        # Complete the command
        completion_data = { success: true, result: { url: "https://example.com" }, error: nil }
        queue.complete_command(command_id, true, completion_data[:result], nil)

        # Result should be available
        result = result_future.value(2) # 2 second timeout
        expect(result[:success]).to be(true)
        expect(result[:result]).to eq(completion_data[:result])
      end

      it "raises timeout error when command takes too long" do
        expect {
          queue.wait_for_result(command_id, timeout: 0.1)
        }.to raise_error(VectorMCP::Browser::CommandQueue::TimeoutError)
      end

      it "cleans up condition after timeout" do
        begin
          queue.wait_for_result(command_id, timeout: 0.1)
        rescue VectorMCP::Browser::CommandQueue::TimeoutError
          # Expected
        end

        result_conditions = queue.instance_variable_get(:@result_conditions)
        expect(result_conditions).not_to have_key(command_id)
      end
    end

    context "with concurrent access" do
      it "handles multiple commands concurrently" do
        command_ids = (1..5).map { |i| "command-#{i}" }
        
        # Start multiple waiters
        futures = command_ids.map do |cmd_id|
          Concurrent::Future.execute do
            queue.wait_for_result(cmd_id, timeout: 2)
          end
        end

        # Complete commands in reverse order
        command_ids.reverse.each_with_index do |cmd_id, index|
          queue.complete_command(cmd_id, true, { index: index }, nil)
          sleep(0.05) # Small delay between completions
        end

        # All should complete successfully
        results = futures.map { |f| f.value(3) }
        expect(results).to all(satisfy { |r| r[:success] })
      end
    end
  end

  describe "error handling" do
    let(:command_id) { "test-command-123" }

    it "handles invalid command completion gracefully" do
      expect {
        queue.complete_command(nil, true, {}, nil)
      }.not_to raise_error
    end

    it "handles waiting for non-existent command" do
      expect {
        queue.wait_for_result("non-existent", timeout: 0.1)
      }.to raise_error(VectorMCP::Browser::CommandQueue::TimeoutError)
    end
  end

  describe "thread safety" do
    it "handles concurrent enqueuing safely" do
      commands = []
      threads = []

      # Create multiple threads enqueuing commands
      10.times do |i|
        threads << Thread.new do
          cmd = { id: "cmd-#{i}", action: "test", params: {} }
          commands << cmd
          queue.enqueue_command(cmd)
        end
      end

      threads.each(&:join)

      # All commands should be enqueued
      pending_commands = queue.get_pending_commands
      expect(pending_commands.size).to eq(10)
    end

    it "handles concurrent completion safely" do
      # Enqueue multiple commands
      command_ids = (1..10).map { |i| "cmd-#{i}" }
      command_ids.each do |cmd_id|
        queue.enqueue_command({ id: cmd_id, action: "test", params: {} })
      end

      # Complete commands concurrently
      threads = command_ids.map do |cmd_id|
        Thread.new do
          queue.complete_command(cmd_id, true, { id: cmd_id }, nil)
        end
      end

      threads.each(&:join)

      # All should be completed
      completed_commands = queue.instance_variable_get(:@completed_commands)
      expect(completed_commands.size).to eq(10)
    end
  end
end