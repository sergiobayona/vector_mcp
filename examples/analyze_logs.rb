#!/usr/bin/env ruby
# frozen_string_literal: true

# VectorMCP Log Analysis Tool
# Analyzes structured logs to provide insights and metrics

require "json"
require "time"

class LogAnalyzer
  def initialize(log_file = "/tmp/vectormcp_operations.log")
    @log_file = log_file
    @events = []
    @stats = {}
  end

  def analyze
    puts "📊 VectorMCP Log Analysis"
    puts "=" * 50
    puts "Log file: #{@log_file}"
    puts

    load_events
    return unless @events.any?

    analyze_components
    analyze_performance
    analyze_user_activity
    analyze_errors
    analyze_browser_operations
    print_summary
  end

  private

  def load_events
    unless File.exist?(@log_file)
      puts "❌ Log file not found: #{@log_file}"
      puts "   Make sure to run a VectorMCP server with logging enabled first."
      return
    end

    File.readlines(@log_file).each do |line|
      begin
        event = JSON.parse(line.strip)
        @events << event if event.is_a?(Hash)
      rescue JSON::ParserError
        # Skip invalid JSON lines
      end
    end

    puts "📄 Loaded #{@events.length} log events"
    
    if @events.empty?
      puts "   No valid events found. Try generating some activity first:"
      puts "   ruby examples/test_structured_logging.rb"
    end
  end

  def analyze_components
    puts "\n🔍 Component Analysis"
    puts "-" * 30

    by_component = @events.group_by { |e| e["component"] || "unknown" }
    
    by_component.each do |component, events|
      levels = events.group_by { |e| e["level"] || "INFO" }
      level_summary = levels.map { |level, evts| "#{level}: #{evts.length}" }.join(", ")
      puts "  #{component}: #{events.length} events (#{level_summary})"
    end
  end

  def analyze_performance
    puts "\n📈 Performance Analysis"
    puts "-" * 30

    # Find events with execution time
    performance_events = @events.select do |e|
      e.dig("context", "execution_time_ms")
    end

    return puts "  No performance data found" if performance_events.empty?

    times = performance_events.map { |e| e.dig("context", "execution_time_ms") }.compact
    
    puts "  Total operations tracked: #{performance_events.length}"
    puts "  Average execution time: #{(times.sum.to_f / times.length).round(2)}ms"
    puts "  Fastest operation: #{times.min}ms"
    puts "  Slowest operation: #{times.max}ms"
    
    # Show slow operations
    slow_ops = performance_events.select { |e| e.dig("context", "execution_time_ms") > 1000 }
    if slow_ops.any?
      puts "  Slow operations (>1s): #{slow_ops.length}"
      slow_ops.first(3).each do |op|
        tool = op.dig("context", "tool") || "unknown"
        time = op.dig("context", "execution_time_ms")
        puts "    - #{tool}: #{time}ms"
      end
    end
  end

  def analyze_user_activity
    puts "\n👤 User Activity Analysis"
    puts "-" * 30

    user_events = @events.select { |e| e.dig("context", "user_id") }
    return puts "  No user activity found" if user_events.empty?

    by_user = user_events.group_by { |e| e.dig("context", "user_id") }
    
    by_user.each do |user_id, events|
      user_role = events.first&.dig("context", "user_role") || "unknown"
      tools_used = events.map { |e| e.dig("context", "tool") }.compact.uniq
      
      puts "  #{user_id} (#{user_role}): #{events.length} actions"
      puts "    Tools used: #{tools_used.join(", ")}" if tools_used.any?
    end
  end

  def analyze_errors
    puts "\n⚠️  Error Analysis"
    puts "-" * 30

    error_events = @events.select { |e| e["level"] == "ERROR" }
    warn_events = @events.select { |e| e["level"] == "WARN" }
    
    puts "  Errors: #{error_events.length}"
    puts "  Warnings: #{warn_events.length}"
    
    if error_events.any?
      error_types = error_events.map { |e| e.dig("context", "error") || e["message"] }.compact
      unique_errors = error_types.uniq
      
      puts "  Error types:"
      unique_errors.first(5).each do |error|
        count = error_types.count(error)
        puts "    - #{error} (#{count}x)"
      end
    end
  end

  def analyze_browser_operations
    puts "\n🌐 Browser Operations Analysis"
    puts "-" * 30

    browser_events = @events.select do |e|
      e["component"]&.start_with?("browser.") || 
      e.dig("context", "tool")&.start_with?("browser_") ||
      e["message"]&.include?("Browser")
    end

    return puts "  No browser operations found" if browser_events.empty?

    # Operations by type
    ops_by_type = browser_events.group_by do |e|
      e.dig("context", "tool") || e.dig("context", "action") || "unknown"
    end

    puts "  Total browser operations: #{browser_events.length}"
    puts "  Operations by type:"
    ops_by_type.each do |type, events|
      success_count = events.count { |e| e.dig("context", "success") != false }
      puts "    #{type}: #{events.length} (#{success_count} successful)"
    end

    # Navigation analysis
    nav_events = browser_events.select { |e| e["message"]&.include?("navigation") }
    if nav_events.any?
      urls = nav_events.map { |e| e.dig("context", "url") }.compact.uniq
      puts "  Unique URLs visited: #{urls.length}"
      urls.first(3).each { |url| puts "    - #{url}" }
    end
  end

  def print_summary
    puts "\n" + "=" * 50
    puts "📋 Summary"
    puts "=" * 50

    time_range = get_time_range
    puts "Time range: #{time_range}" if time_range

    components = @events.map { |e| e["component"] }.compact.uniq.length
    puts "Components active: #{components}"
    
    errors = @events.count { |e| e["level"] == "ERROR" }
    warnings = @events.count { |e| e["level"] == "WARN" }
    
    puts "Error rate: #{errors} errors, #{warnings} warnings in #{@events.length} events"
    
    puts
    puts "💡 Useful analysis commands:"
    puts "  # Real-time monitoring"
    puts "  tail -f #{@log_file} | jq"
    puts
    puts "  # Filter by error level"
    puts "  jq 'select(.level == \"ERROR\")' #{@log_file}"
    puts
    puts "  # Performance monitoring"
    puts "  jq 'select(.context.execution_time_ms > 100)' #{@log_file}"
    puts
    puts "  # User activity"
    puts "  jq 'select(.context.user_id)' #{@log_file}"
    puts
    puts "  # Security events"
    puts "  jq 'select(.component | startswith(\"security\"))' #{@log_file}"
  end

  def get_time_range
    timestamps = @events.map { |e| e["timestamp"] }.compact
    return nil if timestamps.empty?

    begin
      earliest = Time.parse(timestamps.min)
      latest = Time.parse(timestamps.max)
      duration = latest - earliest
      
      "#{earliest.strftime('%H:%M:%S')} - #{latest.strftime('%H:%M:%S')} (#{duration.round(1)}s)"
    rescue StandardError
      nil
    end
  end
end

# Main execution
if __FILE__ == $0
  log_file = ARGV[0] || "/tmp/vectormcp_operations.log"
  
  analyzer = LogAnalyzer.new(log_file)
  analyzer.analyze
end