#!/bin/bash
# Security Logger Hook (All hook types)
# Comprehensive logging for security and audit purposes

# Create log directory if it doesn't exist
log_dir="$HOME/.claude/logs"
mkdir -p "$log_dir"

log_file="$log_dir/vectormcp-audit.log"
timestamp=$(date '+%Y-%m-%d %H:%M:%S')
user=$(whoami)
pwd_dir=$(pwd)

# Log entry header
{
  echo "=========================="
  echo "Timestamp: $timestamp"
  echo "User: $user"
  echo "Directory: $pwd_dir"
  echo "Tool: $TOOL_NAME"
  echo "Hook Type: ${HOOK_TYPE:-unknown}"
} >> "$log_file"

# Log tool-specific information
case "$TOOL_NAME" in
  "Edit"|"MultiEdit"|"Write")
    file_path=$(echo "$TOOL_INPUT" | jq -r '.file_path // "unknown"')
    echo "File Operation: $file_path" >> "$log_file"
    
    # Log sensitive file access attempts
    if [[ "$file_path" =~ \.(env|key|pem|secret)$ ]]; then
      echo "⚠️  SENSITIVE FILE ACCESS: $file_path" >> "$log_file"
    fi
    ;;
    
  "Read")
    file_path=$(echo "$TOOL_INPUT" | jq -r '.file_path // "unknown"')
    echo "File Read: $file_path" >> "$log_file"
    ;;
    
  "Bash")
    command=$(echo "$TOOL_INPUT" | jq -r '.command // "unknown"')
    description=$(echo "$TOOL_INPUT" | jq -r '.description // "No description"')
    echo "Bash Command: $command" >> "$log_file"
    echo "Description: $description" >> "$log_file"
    
    # Flag potentially risky commands
    if [[ "$command" =~ (sudo|rm -rf|chmod 777|curl.*sudo|wget.*sudo) ]]; then
      echo "🚨 HIGH RISK COMMAND DETECTED" >> "$log_file"
    fi
    ;;
    
  "Glob"|"Grep")
    pattern=$(echo "$TOOL_INPUT" | jq -r '.pattern // "unknown"')
    echo "Search Pattern: $pattern" >> "$log_file"
    ;;
    
  *)
    echo "Tool Input: $TOOL_INPUT" >> "$log_file"
    ;;
esac

# Log git context if available
if git rev-parse --git-dir > /dev/null 2>&1; then
  branch=$(git branch --show-current 2>/dev/null || "unknown")
  commit=$(git rev-parse --short HEAD 2>/dev/null || "unknown")
  echo "Git Branch: $branch" >> "$log_file"
  echo "Git Commit: $commit" >> "$log_file"
fi

# Log session ID if available from environment
if [[ -n "$CLAUDE_SESSION_ID" ]]; then
  echo "Session ID: $CLAUDE_SESSION_ID" >> "$log_file"
fi

echo "==========================" >> "$log_file"
echo "" >> "$log_file"

# Rotate log file if it gets too large (>10MB)
if [[ -f "$log_file" ]] && [[ $(stat -f%z "$log_file" 2>/dev/null || stat -c%s "$log_file" 2>/dev/null || echo 0) -gt 10485760 ]]; then
  mv "$log_file" "${log_file}.old"
  echo "Log rotated at $timestamp" > "$log_file"
fi

# Optional: Send alerts for high-risk activities
if [[ "$TOOL_NAME" == "Bash" ]]; then
  command=$(echo "$TOOL_INPUT" | jq -r '.command // ""')
  if [[ "$command" =~ (sudo|rm -rf|format|mkfs) ]]; then
    # Could integrate with notification systems here
    echo "🚨 High-risk command logged: $command" >&2
  fi
fi