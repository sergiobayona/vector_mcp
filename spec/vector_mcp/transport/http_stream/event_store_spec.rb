# frozen_string_literal: true

require "spec_helper"
require "vector_mcp/transport/http_stream/event_store"

RSpec.describe VectorMCP::Transport::HttpStream::EventStore do
  let(:max_events) { 10 }
  let(:event_store) { described_class.new(max_events) }
  let(:test_data) { "test event data" }
  let(:test_type) { "test_event" }

  describe "#initialize" do
    it "initializes with max_events" do
      expect(event_store.max_events).to eq(max_events)
    end

    it "starts with empty events" do
      expect(event_store.event_count).to eq(0)
    end

    it "initializes with thread-safe collections" do
      expect(event_store.instance_variable_get(:@events)).to be_a(Concurrent::Array)
      expect(event_store.instance_variable_get(:@event_index)).to be_a(Concurrent::Hash)
      expect(event_store.instance_variable_get(:@current_sequence)).to be_a(Concurrent::AtomicFixnum)
    end
  end

  describe "#store_event" do
    it "stores an event and returns event ID" do
      event_id = event_store.store_event(test_data, test_type)
      
      expect(event_id).to be_a(String)
      expect(event_id).not_to be_empty
      expect(event_store.event_count).to eq(1)
    end

    it "stores event without type" do
      event_id = event_store.store_event(test_data)
      
      expect(event_id).to be_a(String)
      expect(event_store.event_count).to eq(1)
    end

    it "generates unique event IDs" do
      event_id1 = event_store.store_event("data1")
      event_id2 = event_store.store_event("data2")
      
      expect(event_id1).not_to eq(event_id2)
    end

    it "maintains circular buffer when max_events exceeded" do
      # Fill up to max_events
      event_ids = []
      (max_events + 3).times do |i|
        event_ids << event_store.store_event("data#{i}")
      end
      
      expect(event_store.event_count).to eq(max_events)
      
      # First 3 events should be removed
      expect(event_store.event_exists?(event_ids[0])).to be false
      expect(event_store.event_exists?(event_ids[1])).to be false
      expect(event_store.event_exists?(event_ids[2])).to be false
      
      # Last max_events should remain
      expect(event_store.event_exists?(event_ids[3])).to be true
      expect(event_store.event_exists?(event_ids.last)).to be true
    end

    it "updates event index correctly after circular buffer rotation" do
      # Fill beyond max_events
      event_ids = []
      (max_events + 2).times do |i|
        event_ids << event_store.store_event("data#{i}")
      end
      
      # Verify index is updated correctly
      events_after = event_store.get_events_after(nil)
      expect(events_after.length).to eq(max_events)
      
      # Check that we can retrieve events from the middle
      middle_event_id = event_ids[max_events - 5]
      events_after_middle = event_store.get_events_after(middle_event_id)
      expect(events_after_middle.length).to be > 0
    end

    it "sets timestamp on stored events" do
      freeze_time = Time.now
      allow(Time).to receive(:now).and_return(freeze_time)
      
      event_id = event_store.store_event(test_data)
      events = event_store.get_events_after(nil)
      
      expect(events.first.timestamp).to eq(freeze_time)
    end
  end

  describe "#get_events_after" do
    let!(:event_ids) do
      5.times.map { |i| event_store.store_event("data#{i}", "type#{i}") }
    end

    it "returns all events when last_event_id is nil" do
      events = event_store.get_events_after(nil)
      
      expect(events.length).to eq(5)
      expect(events.map(&:data)).to eq(["data0", "data1", "data2", "data3", "data4"])
    end

    it "returns events after specified last_event_id" do
      events = event_store.get_events_after(event_ids[2])
      
      expect(events.length).to eq(2)
      expect(events.map(&:data)).to eq(["data3", "data4"])
    end

    it "returns empty array when last_event_id is the newest event" do
      events = event_store.get_events_after(event_ids.last)
      
      expect(events).to be_empty
    end

    it "returns empty array when last_event_id does not exist" do
      events = event_store.get_events_after("non-existent-id")
      
      expect(events).to be_empty
    end

    it "returns empty array when no events exist" do
      empty_store = described_class.new(10)
      events = empty_store.get_events_after("any-id")
      
      expect(events).to be_empty
    end
  end

  describe "#event_count" do
    it "returns zero for empty store" do
      expect(event_store.event_count).to eq(0)
    end

    it "returns correct count after storing events" do
      3.times { |i| event_store.store_event("data#{i}") }
      
      expect(event_store.event_count).to eq(3)
    end

    it "does not exceed max_events" do
      (max_events + 5).times { |i| event_store.store_event("data#{i}") }
      
      expect(event_store.event_count).to eq(max_events)
    end
  end

  describe "#oldest_event_id" do
    it "returns nil for empty store" do
      expect(event_store.oldest_event_id).to be_nil
    end

    it "returns oldest event ID" do
      event_ids = 3.times.map { |i| event_store.store_event("data#{i}") }
      
      expect(event_store.oldest_event_id).to eq(event_ids.first)
    end

    it "returns correct oldest event ID after circular buffer rotation" do
      event_ids = (max_events + 3).times.map { |i| event_store.store_event("data#{i}") }
      
      # After rotation, oldest should be event at index 3
      expect(event_store.oldest_event_id).to eq(event_ids[3])
    end
  end

  describe "#newest_event_id" do
    it "returns nil for empty store" do
      expect(event_store.newest_event_id).to be_nil
    end

    it "returns newest event ID" do
      event_ids = 3.times.map { |i| event_store.store_event("data#{i}") }
      
      expect(event_store.newest_event_id).to eq(event_ids.last)
    end

    it "returns correct newest event ID after circular buffer rotation" do
      event_ids = (max_events + 3).times.map { |i| event_store.store_event("data#{i}") }
      
      expect(event_store.newest_event_id).to eq(event_ids.last)
    end
  end

  describe "#event_exists?" do
    let!(:event_id) { event_store.store_event(test_data) }

    it "returns true for existing event" do
      expect(event_store.event_exists?(event_id)).to be true
    end

    it "returns false for non-existent event" do
      expect(event_store.event_exists?("non-existent")).to be false
    end

    it "returns false for removed event after circular buffer rotation" do
      # Fill beyond max_events
      (max_events + 1).times { |i| event_store.store_event("data#{i}") }
      
      expect(event_store.event_exists?(event_id)).to be false
    end
  end

  describe "#clear" do
    before do
      5.times { |i| event_store.store_event("data#{i}") }
    end

    it "removes all events" do
      expect(event_store.event_count).to eq(5)
      
      event_store.clear
      
      expect(event_store.event_count).to eq(0)
    end

    it "clears event index" do
      event_store.clear
      
      expect(event_store.event_exists?("any-id")).to be false
    end

    it "allows storing events after clear" do
      event_store.clear
      
      new_event_id = event_store.store_event("new_data")
      expect(event_store.event_count).to eq(1)
      expect(event_store.event_exists?(new_event_id)).to be true
    end
  end

  describe "#stats" do
    it "returns correct stats for empty store" do
      stats = event_store.stats
      
      expect(stats[:total_events]).to eq(0)
      expect(stats[:max_events]).to eq(max_events)
      expect(stats[:oldest_event_id]).to be_nil
      expect(stats[:newest_event_id]).to be_nil
      expect(stats[:memory_usage_ratio]).to eq(0.0)
    end

    it "returns correct stats with events" do
      event_ids = 3.times.map { |i| event_store.store_event("data#{i}") }
      stats = event_store.stats
      
      expect(stats[:total_events]).to eq(3)
      expect(stats[:max_events]).to eq(max_events)
      expect(stats[:oldest_event_id]).to eq(event_ids.first)
      expect(stats[:newest_event_id]).to eq(event_ids.last)
      expect(stats[:memory_usage_ratio]).to eq(0.3)
    end

    it "returns correct stats at full capacity" do
      event_ids = max_events.times.map { |i| event_store.store_event("data#{i}") }
      stats = event_store.stats
      
      expect(stats[:total_events]).to eq(max_events)
      expect(stats[:memory_usage_ratio]).to eq(1.0)
    end
  end

  describe "Event struct" do
    describe "#to_sse_format" do
      it "formats event with all fields" do
        event = VectorMCP::Transport::HttpStream::EventStore::Event.new(
          "event-123", "test data", "test_type", Time.now
        )
        
        sse_format = event.to_sse_format
        
        expect(sse_format).to include("id: event-123")
        expect(sse_format).to include("event: test_type")
        expect(sse_format).to include("data: test data")
        expect(sse_format).to end_with("\n")
      end

      it "formats event without type" do
        event = VectorMCP::Transport::HttpStream::EventStore::Event.new(
          "event-123", "test data", nil, Time.now
        )
        
        sse_format = event.to_sse_format
        
        expect(sse_format).to include("id: event-123")
        expect(sse_format).to include("data: test data")
        expect(sse_format).not_to include("event:")
        expect(sse_format).to end_with("\n")
      end
    end
  end

  describe "thread safety" do
    it "handles concurrent event storage" do
      threads = []
      event_ids = Concurrent::Array.new
      
      10.times do |i|
        threads << Thread.new do
          5.times do |j|
            event_id = event_store.store_event("thread#{i}_event#{j}")
            event_ids << event_id
          end
        end
      end
      
      threads.each(&:join)
      
      # All events should be unique
      expect(event_ids.uniq.length).to eq(event_ids.length)
      
      # Store should not exceed max_events
      expect(event_store.event_count).to eq([50, max_events].min)
    end

    it "handles concurrent reads and writes" do
      # Start background thread storing events
      writer_thread = Thread.new do
        100.times { |i| event_store.store_event("concurrent_data#{i}") }
      end
      
      # Perform concurrent reads
      reader_threads = 5.times.map do
        Thread.new do
          10.times do
            event_store.get_events_after(nil)
            event_store.event_count
            event_store.oldest_event_id
            event_store.newest_event_id
          end
        end
      end
      
      writer_thread.join
      reader_threads.each(&:join)
      
      # No exceptions should be raised
      expect(event_store.event_count).to eq([100, max_events].min)
    end
  end

  describe "edge cases" do
    it "handles empty string data" do
      event_id = event_store.store_event("")
      
      expect(event_id).to be_a(String)
      expect(event_store.event_count).to eq(1)
      
      events = event_store.get_events_after(nil)
      expect(events.first.data).to eq("")
    end

    it "handles nil type" do
      event_id = event_store.store_event("data", nil)
      
      events = event_store.get_events_after(nil)
      expect(events.first.type).to be_nil
    end

    it "handles max_events of 1" do
      small_store = described_class.new(1)
      
      event_id1 = small_store.store_event("data1")
      event_id2 = small_store.store_event("data2")
      
      expect(small_store.event_count).to eq(1)
      expect(small_store.event_exists?(event_id1)).to be false
      expect(small_store.event_exists?(event_id2)).to be true
    end

    it "handles large max_events" do
      large_store = described_class.new(10000)
      
      1000.times { |i| large_store.store_event("data#{i}") }
      
      expect(large_store.event_count).to eq(1000)
    end
  end

  describe "private methods" do
    describe "#generate_event_id" do
      it "generates unique IDs" do
        event_ids = 100.times.map { event_store.send(:generate_event_id) }
        
        expect(event_ids.uniq.length).to eq(100)
      end

      it "includes timestamp, sequence, and random component" do
        event_id = event_store.send(:generate_event_id)
        
        # Format: timestamp-sequence-random
        parts = event_id.split('-')
        expect(parts.length).to eq(3)
        
        # Timestamp should be a valid integer
        expect(parts[0].to_i).to be > 0
        
        # Sequence should be a positive integer
        expect(parts[1].to_i).to be > 0
        
        # Random component should be hex string
        expect(parts[2]).to match(/^[0-9a-f]{8}$/)
      end
    end
  end
end