#!/bin/bash
# Dependency Tracking Hook (PostToolUse)
# Tracks new dependencies and suggests Gemfile updates

# Only run for Ruby file edits
if [[ "$TOOL_NAME" == "Edit" || "$TOOL_NAME" == "MultiEdit" || "$TOOL_NAME" == "Write" ]]; then
  file_path=$(echo "$TOOL_INPUT" | jq -r '.file_path // empty')
  
  if [[ "$file_path" == *.rb && -f "$file_path" ]]; then
    echo "📦 Checking for new dependencies in $file_path..."
    
    # Extract require statements (excluding vector_mcp internal requires)
    new_requires=$(grep -E "require ['\"][^'\"]*['\"]" "$file_path" | \
                   grep -v "vector_mcp" | \
                   grep -v "require_relative" | \
                   sed -E "s/.*require ['\"]([^'\"]*)['\"].*/\1/" | \
                   sort -u)
    
    if [[ -n "$new_requires" ]]; then
      echo "🔍 Found require statements:"
      echo "$new_requires" | while read -r req; do
        echo "  - $req"
        
        # Check if it's a standard library or common gem
        case "$req" in
          "json"|"base64"|"uri"|"net/http"|"openssl"|"digest"|"time"|"logger")
            echo "    ℹ️  Standard library - no Gemfile update needed"
            ;;
          "concurrent-ruby"|"json-schema"|"jwt"|"puma"|"rack")
            echo "    ✅ Already in Gemfile"
            ;;
          *)
            echo "    ⚠️  May need Gemfile update if this is a new external dependency"
            
            # Check if it's already in Gemfile
            if [[ -f "Gemfile" ]] && grep -q "$req" Gemfile; then
              echo "    ✅ Found in Gemfile"
            else
              echo "    📝 Consider adding to Gemfile if this is an external gem"
            fi
            ;;
        esac
      done
      
      echo ""
      echo "💡 Dependency Review Checklist:"
      echo "  □ Are all new external dependencies added to Gemfile?"
      echo "  □ Are version constraints appropriate?"
      echo "  □ Have you run 'bundle install' if needed?"
      echo "  □ Are new dependencies documented in README?"
    fi
    
    # Check for new class/module definitions that might indicate API changes
    new_classes=$(grep -E "^class |^module " "$file_path" | sed -E "s/.*(class|module) ([A-Za-z0-9_:]+).*/\2/")
    if [[ -n "$new_classes" ]]; then
      echo "🏗️  New classes/modules detected:"
      echo "$new_classes" | while read -r class_name; do
        echo "  - $class_name"
      done
      echo "  💡 Consider updating API documentation if these are public interfaces"
    fi
  fi
fi