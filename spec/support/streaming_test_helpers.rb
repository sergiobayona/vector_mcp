# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "timeout"
require "concurrent-ruby"

module StreamingTestHelpers
  # Enhanced mock streaming client for testing HTTP streaming features
  class MockStreamingClient
    attr_reader :session_id, :base_url, :events_received, :connection_state
    
    def initialize(session_id, base_url)
      @session_id = session_id
      @base_url = base_url
      @events_received = Concurrent::Array.new
      @sampling_responses = Concurrent::Hash.new
      @connection_state = :disconnected
      @running = false
      @stream_thread = nil
      @response_handlers = {}
      @error_handlers = {}
      @connection_callbacks = {}
      @mutex = Mutex.new
    end

    # Start streaming connection
    def start_streaming(headers: {})
      @mutex.synchronize do
        return false if @running
        @running = true
        @connection_state = :connecting
      end

      @stream_thread = Thread.new do
        begin
          handle_stream(headers)
        rescue => e
          @connection_state = :error
          handle_error(:connection_error, e)
        ensure
          @connection_state = :disconnected
          @running = false
        end
      end

      # Wait for connection to establish
      wait_for_connection_state(:connected, timeout: 5)
    end

    # Stop streaming connection
    def stop_streaming
      @mutex.synchronize do
        @running = false
      end
      
      @stream_thread&.join(2)
      @stream_thread&.kill if @stream_thread&.alive?
      @stream_thread = nil
      @connection_state = :disconnected
    end

    # Configure response for sampling requests
    def set_sampling_response(method, response)
      @sampling_responses[method] = response
    end

    # Configure response handler for specific methods
    def on_method(method, &block)
      @response_handlers[method] = block
    end

    # Configure error handler
    def on_error(error_type, &block)
      @error_handlers[error_type] = block
    end

    # Configure connection state callback
    def on_connection_state(state, &block)
      @connection_callbacks[state] = block
    end

    # Wait for specific number of events
    def wait_for_events(count, timeout: 10)
      Timeout.timeout(timeout) do
        sleep(0.1) until @events_received.size >= count
      end
      @events_received.first(count)
    end

    # Wait for specific connection state
    def wait_for_connection_state(state, timeout: 10)
      Timeout.timeout(timeout) do
        sleep(0.1) until @connection_state == state
      end
      true
    rescue Timeout::Error
      false
    end

    # Get last N events
    def last_events(count = 1)
      @events_received.last(count)
    end

    # Check if connected
    def connected?
      @connection_state == :connected
    end

    # Get connection statistics
    def stats
      {
        session_id: @session_id,
        connection_state: @connection_state,
        events_received: @events_received.size,
        sampling_responses_configured: @sampling_responses.size,
        is_running: @running
      }
    end

    private

    def handle_stream(headers)
      uri = URI("#{@base_url}/mcp")
      http = Net::HTTP.new(uri.host, uri.port)
      http.read_timeout = 60 # Long timeout for streaming

      request = Net::HTTP::Get.new(uri)
      request["Mcp-Session-Id"] = @session_id
      request["Accept"] = "text/event-stream"
      request["Cache-Control"] = "no-cache"
      headers.each { |k, v| request[k] = v }

      http.request(request) do |response|
        if response.code.to_i == 200
          @connection_state = :connected
          trigger_callback(:connected)
          
          buffer = ""
          response.read_body do |chunk|
            break unless @running
            
            buffer += chunk
            
            # Process complete events (ending with double newline)
            while buffer.include?("\n\n")
              event_data, buffer = buffer.split("\n\n", 2)
              process_sse_event(event_data) unless event_data.strip.empty?
            end
          end
        else
          @connection_state = :error
          handle_error(:http_error, "HTTP #{response.code}: #{response.message}")
        end
      end
    end

    def process_sse_event(event_data)
      event = parse_sse_event(event_data)
      @events_received << event
      
      # Handle server-initiated requests
      if event[:data] && event[:data].is_a?(Hash) && event[:data]["method"]
        handle_server_request(event[:data])
      end
      
      # Trigger method-specific handler
      if event[:data] && event[:data].is_a?(Hash) && event[:data]["method"]
        method = event[:data]["method"]
        handler = @response_handlers[method]
        handler.call(event) if handler
      end
    end

    def parse_sse_event(event_data)
      event = {
        id: nil,
        event: nil,
        data: nil,
        raw: event_data
      }

      event_data.split("\n").each do |line|
        case line
        when /^id:\s*(.+)$/
          event[:id] = $1.strip
        when /^event:\s*(.+)$/
          event[:event] = $1.strip
        when /^data:\s*(.+)$/
          data_str = $1.strip
          begin
            event[:data] = JSON.parse(data_str)
          rescue JSON::ParserError
            event[:data] = data_str
          end
        end
      end

      event
    end

    def handle_server_request(message)
      method = message["method"]
      request_id = message["id"]
      
      return unless request_id # Only handle requests, not notifications
      
      case method
      when "sampling/createMessage"
        handle_sampling_request(message)
      else
        # Handle other server-initiated requests
        response = @sampling_responses[method] || "Mock response for #{method}"
        send_response(request_id, response)
      end
    end

    def handle_sampling_request(message)
      request_id = message["id"]
      params = message["params"] || {}
      
      # Generate appropriate response based on configuration
      response_content = @sampling_responses["sampling/createMessage"] || 
                        generate_default_sampling_response(params)
      
      send_sampling_response(request_id, response_content)
    end

    def generate_default_sampling_response(params)
      messages = params["messages"] || []
      last_message = messages.last
      
      if last_message && last_message["content"]
        content = last_message["content"]
        if content.is_a?(Hash) && content["text"]
          "Mock response to: #{content["text"]}"
        else
          "Mock response to your message"
        end
      else
        "Mock response from streaming client"
      end
    end

    def send_sampling_response(request_id, content)
      response = {
        jsonrpc: "2.0",
        id: request_id,
        result: {
          model: "test-model",
          role: "assistant",
          content: {
            type: "text",
            text: content
          }
        }
      }
      
      send_response_to_server(response)
    end

    def send_response(request_id, result)
      response = {
        jsonrpc: "2.0",
        id: request_id,
        result: result
      }
      
      send_response_to_server(response)
    end

    def send_response_to_server(response)
      uri = URI("#{@base_url}/mcp")
      http = Net::HTTP.new(uri.host, uri.port)
      
      request = Net::HTTP::Post.new(uri)
      request["Mcp-Session-Id"] = @session_id
      request["Content-Type"] = "application/json"
      request.body = response.to_json
      
      http.request(request)
    end

    def handle_error(error_type, error)
      handler = @error_handlers[error_type]
      handler.call(error) if handler
    end

    def trigger_callback(state)
      callback = @connection_callbacks[state]
      callback.call if callback
    end
  end

  # Server-Sent Events parser utility
  class SSEParser
    def self.parse_event(event_data)
      event = {
        id: nil,
        event: nil,
        data: nil,
        retry_interval: nil
      }

      event_data.split("\n").each do |line|
        case line
        when /^id:\s*(.+)$/
          event[:id] = $1.strip
        when /^event:\s*(.+)$/
          event[:event] = $1.strip
        when /^data:\s*(.+)$/
          data_str = $1.strip
          begin
            event[:data] = JSON.parse(data_str)
          rescue JSON::ParserError
            event[:data] = data_str
          end
        when /^retry:\s*(\d+)$/
          event[:retry_interval] = $1.to_i
        end
      end

      event
    end

    def self.format_event(id: nil, event: nil, data: nil, retry_interval: nil)
      lines = []
      lines << "id: #{id}" if id
      lines << "event: #{event}" if event
      lines << "data: #{data.is_a?(String) ? data : data.to_json}" if data
      lines << "retry: #{retry_interval}" if retry_interval
      lines.join("\n") + "\n\n"
    end
  end

  # Test utilities for streaming scenarios
  module StreamingTestUtils
    # Create multiple streaming clients
    def create_streaming_clients(count, base_url, session_prefix = "stream-test")
      clients = []
      count.times do |i|
        session_id = "#{session_prefix}-#{i}"
        client = MockStreamingClient.new(session_id, base_url)
        clients << client
        yield(client, i) if block_given?
      end
      clients
    end

    # Wait for all clients to connect
    def wait_for_clients_connected(clients, timeout: 10)
      Timeout.timeout(timeout) do
        sleep(0.1) until clients.all?(&:connected?)
      end
      true
    rescue Timeout::Error
      false
    end

    # Stop all streaming clients
    def stop_all_clients(clients)
      clients.each(&:stop_streaming)
    end

    # Simulate network issues
    def simulate_network_interruption(duration = 1)
      # This would typically involve network manipulation
      # For testing, we can simulate by stopping/starting clients
      sleep(duration)
    end

    # Generate test event data
    def generate_test_events(count, prefix = "test-event")
      events = []
      count.times do |i|
        events << {
          id: "#{prefix}-#{i}",
          event: "test",
          data: { 
            message: "Test event #{i}",
            timestamp: Time.now.to_f,
            sequence: i
          }
        }
      end
      events
    end

    # Validate event ordering
    def validate_event_sequence(events, expected_count)
      return false if events.size != expected_count
      
      events.each_with_index do |event, index|
        return false unless event[:data] && event[:data]["sequence"] == index
      end
      
      true
    end
  end

  # HTTP streaming connection wrapper
  class StreamingConnection
    attr_reader :session_id, :base_url, :state

    def initialize(session_id, base_url)
      @session_id = session_id
      @base_url = base_url
      @state = :disconnected
      @events = []
      @connection = nil
    end

    def connect(headers: {})
      @state = :connecting
      
      uri = URI("#{@base_url}/mcp")
      @connection = Net::HTTP.new(uri.host, uri.port)
      
      request = Net::HTTP::Get.new(uri)
      request["Mcp-Session-Id"] = @session_id
      request["Accept"] = "text/event-stream"
      request["Cache-Control"] = "no-cache"
      headers.each { |k, v| request[k] = v }
      
      @connection.request(request) do |response|
        if response.code.to_i == 200
          @state = :connected
          yield response if block_given?
        else
          @state = :error
          raise "Connection failed: #{response.code}"
        end
      end
    rescue => e
      @state = :error
      raise e
    end

    def disconnect
      @connection&.finish if @connection&.started?
      @connection = nil
      @state = :disconnected
    end

    def connected?
      @state == :connected
    end
  end
end