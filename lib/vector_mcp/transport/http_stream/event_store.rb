# frozen_string_literal: true

require "concurrent-ruby"
require "securerandom"

module VectorMCP
  module Transport
    class HttpStream
      # Manages Server-Sent Events storage for resumable connections.
      #
      # Handles:
      # - Event storage with unique IDs
      # - Event replay from a specific Last-Event-ID
      # - Circular buffer for memory efficiency
      # - Thread-safe operations
      #
      # @api private
      class EventStore
        # Event data structure
        Event = Struct.new(:id, :data, :type, :timestamp, :session_id, :stream_id) do
          def to_sse_format
            lines = []
            lines << "id: #{id}"
            lines << "event: #{type}" if type
            lines << "data: #{data}"
            lines << ""
            lines.join("\n")
          end
        end

        attr_reader :max_events, :logger

        # Initializes a new event store.
        #
        # @param max_events [Integer] Maximum number of events to retain
        def initialize(max_events)
          @max_events = max_events
          @events = Concurrent::Array.new
          @event_index = Concurrent::Hash.new # event_id -> index for fast lookup
          @current_sequence = Concurrent::AtomicFixnum.new(0)
        end

        # Stores a new event and returns its ID.
        #
        # @param data [String] The event data
        # @param type [String] The event type (optional)
        # @param session_id [String, nil] The session ID to scope this event to
        # @param stream_id [String, nil] The stream ID to scope this event to
        # @return [String] The generated event ID
        def store_event(data, type = nil, session_id: nil, stream_id: nil)
          event_id = generate_event_id
          timestamp = Time.now

          event = Event.new(event_id, data, type, timestamp, session_id, stream_id)

          # Add to events array
          @events.push(event)

          # Update index
          @event_index[event_id] = @events.length - 1

          # Maintain circular buffer
          if @events.length > @max_events
            removed_event = @events.shift
            @event_index.delete(removed_event.id)

            # Update all indices after removal
            @event_index.transform_values! { |index| index - 1 }
          end

          event_id
        end

        # Retrieves events starting from a specific event ID, optionally filtered by session.
        #
        # @param last_event_id [String] The last event ID received by client
        # @param session_id [String, nil] Filter events to this session only
        # @param stream_id [String, nil] Filter events to this stream only
        # @return [Array<Event>] Array of events after the specified ID
        def get_events_after(last_event_id, session_id: nil, stream_id: nil)
          events = if last_event_id.nil?
                     @events.to_a
                   else
                     last_index = @event_index[last_event_id]
                     return [] if last_index.nil?

                     start_index = last_index + 1
                     return [] if start_index >= @events.length

                     @events[start_index..]
                   end

          events = events.select { |e| e.session_id == session_id } if session_id
          events = events.select { |e| e.stream_id == stream_id } if stream_id
          events
        end

        # Retrieves a specific event by ID.
        #
        # @param event_id [String] The event ID to look up
        # @return [Event, nil] The stored event, or nil if it is no longer retained
        def get_event(event_id)
          index = @event_index[event_id]
          return nil if index.nil?

          @events[index]
        end

        # Gets the total number of stored events.
        #
        # @return [Integer] Number of events currently stored
        def event_count
          @events.length
        end

        # Gets the oldest event ID (for debugging/monitoring).
        #
        # @return [String, nil] The oldest event ID or nil if no events
        def oldest_event_id
          @events.first&.id
        end

        # Gets the newest event ID (for debugging/monitoring).
        #
        # @return [String, nil] The newest event ID or nil if no events
        def newest_event_id
          @events.last&.id
        end

        # Checks if an event ID exists in the store.
        #
        # @param event_id [String] The event ID to check
        # @return [Boolean] True if event exists
        def event_exists?(event_id)
          @event_index.key?(event_id)
        end

        # Clears all stored events.
        #
        # @return [void]
        def clear
          @events.clear
          @event_index.clear
        end

        # Gets statistics about the event store.
        #
        # @return [Hash] Statistics hash
        def stats
          {
            total_events: event_count,
            max_events: @max_events,
            oldest_event_id: oldest_event_id,
            newest_event_id: newest_event_id,
            memory_usage_ratio: event_count.to_f / @max_events
          }
        end

        private

        # Generates a unique event ID.
        #
        # @return [String] A unique event ID
        def generate_event_id
          sequence = @current_sequence.increment
          "#{Time.now.to_i}-#{sequence}-#{SecureRandom.hex(4)}"
        end
      end
    end
  end
end
