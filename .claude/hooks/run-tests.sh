#!/bin/bash
# Automatic Test Running Hook (PostToolUse)
# Runs relevant tests after code changes in lib/vector_mcp/

# Only run for Edit, MultiEdit, or Write operations
if [[ "$TOOL_NAME" == "Edit" || "$TOOL_NAME" == "MultiEdit" || "$TOOL_NAME" == "Write" ]]; then
  # Extract file path from tool input
  file_path=$(echo "$TOOL_INPUT" | jq -r '.file_path // empty')
  
  # Only process files in lib/vector_mcp/
  if [[ "$file_path" == lib/vector_mcp/* && "$file_path" == *.rb ]]; then
    echo "🧪 Running tests for changes in $file_path..."
    
    # Convert lib path to spec path (lib/vector_mcp/foo.rb -> spec/vector_mcp/foo_spec.rb)
    spec_file="${file_path/lib/spec}"
    spec_file="${spec_file/.rb/_spec.rb}"
    
    if [[ -f "$spec_file" ]]; then
      echo "🔍 Running specific test file: $spec_file"
      if bundle exec rspec "$spec_file" --format progress --no-profile; then
        echo "✅ Tests passed for $spec_file"
      else
        echo "❌ Tests failed for $spec_file - please review changes"
      fi
    else
      echo "📝 No specific test file found for $spec_file"
      echo "🔍 Running related tests..."
      
      # Extract the component name (e.g., server, transport, security)
      component=$(echo "$file_path" | sed 's|lib/vector_mcp/||' | cut -d'/' -f1)
      component_spec="spec/vector_mcp/${component}*"
      
      if ls $component_spec 2>/dev/null | head -1 >/dev/null; then
        echo "🧪 Running tests for component: $component"
        bundle exec rspec $component_spec --format progress --no-profile
      else
        echo "🔄 Running full test suite to ensure no regressions..."
        bundle exec rspec --format progress --no-profile
      fi
    fi
  fi
fi