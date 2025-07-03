#!/bin/bash
# RuboCop Auto-Fix Hook (PostToolUse)
# Automatically runs RuboCop style corrections after Ruby file edits

# Only run for Edit, MultiEdit, or Write operations
if [[ "$TOOL_NAME" == "Edit" || "$TOOL_NAME" == "MultiEdit" || "$TOOL_NAME" == "Write" ]]; then
  # Extract file path from tool input
  file_path=$(echo "$TOOL_INPUT" | jq -r '.file_path // empty')
  
  # Only process Ruby files
  if [[ "$file_path" == *.rb && -f "$file_path" ]]; then
    echo "🔧 Running RuboCop auto-corrections on $file_path..."
    
    # Run RuboCop with auto-correct (safe corrections only)
    if bundle exec rubocop "$file_path" --auto-correct --format quiet 2>/dev/null; then
      echo "✅ Auto-corrected Ruby style issues in $file_path"
    else
      # If RuboCop fails, show a brief message but don't block
      echo "⚠️  RuboCop encountered issues with $file_path (manual review may be needed)"
    fi
  fi
fi