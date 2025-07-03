#!/bin/bash
# Security & Validation Hook (PreToolUse)
# Prevents access to sensitive files and validates operations

# Security check for sensitive file access
if [[ "$TOOL_NAME" == "Read" || "$TOOL_NAME" == "Edit" || "$TOOL_NAME" == "Write" ]]; then
  # Extract file path from tool input
  file_path=$(echo "$TOOL_INPUT" | jq -r '.file_path // empty')
  
  if [[ -n "$file_path" ]]; then
    # Check for sensitive file extensions
    if [[ "$file_path" =~ \.(key|pem|env|secret|p12|pfx|crt|cer)$ ]]; then
      echo "🚫 SECURITY BLOCK: Attempting to access sensitive file: $file_path"
      echo "   File appears to contain credentials or certificates."
      echo "   If access is needed, please handle manually with appropriate security measures."
      exit 1
    fi
    
    # Check for sensitive directories
    if [[ "$file_path" =~ /.ssh/|/.aws/|/.config/|/etc/passwd|/etc/shadow ]]; then
      echo "🚫 SECURITY BLOCK: Attempting to access sensitive system directory: $file_path"
      echo "   This path contains system credentials or configuration."
      exit 1
    fi
    
    # Check for files with potential secrets in the name
    if [[ "$file_path" =~ (secret|password|credential|token|api_key) ]]; then
      echo "⚠️  SECURITY WARNING: File name suggests sensitive content: $file_path"
      echo "   Proceeding with caution. Ensure no secrets are exposed."
    fi
  fi
fi

# Additional validation for bash commands
if [[ "$TOOL_NAME" == "Bash" ]]; then
  command=$(echo "$TOOL_INPUT" | jq -r '.command // empty')
  
  # Warn about potentially destructive commands
  if [[ "$command" =~ (rm -rf|sudo rm|format|mkfs|dd if=) ]]; then
    echo "⚠️  SECURITY WARNING: Potentially destructive command detected:"
    echo "   Command: $command"
    echo "   Please review carefully before proceeding."
  fi
  
  # Block commands that might expose sensitive data
  if [[ "$command" =~ (cat.*\.env|echo.*API_KEY|printenv.*SECRET) ]]; then
    echo "🚫 SECURITY BLOCK: Command may expose sensitive environment variables"
    echo "   Command: $command"
    exit 1
  fi
fi