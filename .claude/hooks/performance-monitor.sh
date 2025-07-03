#!/bin/bash
# Performance Monitoring Hook (PostToolUse)
# Tracks performance of critical operations and test execution

# Only monitor specific operations
if [[ "$TOOL_NAME" == "Bash" ]]; then
  command=$(echo "$TOOL_INPUT" | jq -r '.command // ""')
  
  # Monitor test execution performance
  if [[ "$command" =~ "bundle exec rspec" ]]; then
    echo "⏱️  Test execution completed at $(date)"
    
    # Log test performance metrics
    perf_log="$HOME/.claude/logs/performance.log"
    mkdir -p "$(dirname "$perf_log")"
    
    {
      echo "$(date '+%Y-%m-%d %H:%M:%S') - RSpec execution"
      echo "Command: $command"
      
      # Extract test results if available from recent execution
      if [[ -f "rspec.log" ]]; then
        tail -5 rspec.log | grep -E "(examples|failures|pending)"
      fi
      
      echo "---"
    } >> "$perf_log"
    
    echo "📊 Test performance logged"
  fi
  
  # Monitor RuboCop performance
  if [[ "$command" =~ "bundle exec rubocop" ]]; then
    echo "⏱️  RuboCop execution completed at $(date)"
    
    perf_log="$HOME/.claude/logs/performance.log"
    mkdir -p "$(dirname "$perf_log")"
    
    {
      echo "$(date '+%Y-%m-%d %H:%M:%S') - RuboCop execution"
      echo "Command: $command"
      echo "---"
    } >> "$perf_log"
  fi
  
  # Monitor bundle operations
  if [[ "$command" =~ "bundle " ]]; then
    echo "📦 Bundle operation completed: $command"
    
    # Log slow bundle operations
    if [[ "$command" =~ "bundle install|bundle update" ]]; then
      perf_log="$HOME/.claude/logs/performance.log"
      mkdir -p "$(dirname "$perf_log")"
      
      {
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Bundle operation"
        echo "Command: $command"
        echo "---"
      } >> "$perf_log"
    fi
  fi
fi

# Monitor file operation patterns
if [[ "$TOOL_NAME" == "Edit" || "$TOOL_NAME" == "MultiEdit" || "$TOOL_NAME" == "Write" ]]; then
  file_path=$(echo "$TOOL_INPUT" | jq -r '.file_path // ""')
  
  # Track large file operations
  if [[ -f "$file_path" ]]; then
    file_size=$(stat -f%z "$file_path" 2>/dev/null || stat -c%s "$file_path" 2>/dev/null || echo 0)
    
    # Log operations on large files (>100KB)
    if [[ "$file_size" -gt 102400 ]]; then
      perf_log="$HOME/.claude/logs/performance.log"
      mkdir -p "$(dirname "$perf_log")"
      
      {
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Large file operation"
        echo "File: $file_path"
        echo "Size: $file_size bytes"
        echo "Operation: $TOOL_NAME"
        echo "---"
      } >> "$perf_log"
      
      echo "📏 Large file operation logged: $(basename "$file_path") ($file_size bytes)"
    fi
  fi
fi

# Performance summary (run periodically)
perf_log="$HOME/.claude/logs/performance.log"
if [[ -f "$perf_log" ]]; then
  # Count operations in the last hour
  one_hour_ago=$(date -d '1 hour ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -v-1H '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
  
  if [[ -n "$one_hour_ago" ]]; then
    recent_ops=$(awk -v since="$one_hour_ago" '$0 >= since' "$perf_log" | grep -c "execution\|operation" || echo 0)
    
    if [[ "$recent_ops" -gt 10 ]]; then
      echo "📈 High activity: $recent_ops operations in the last hour"
    fi
  fi
fi