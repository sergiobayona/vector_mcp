#!/bin/bash
# Example Code Validation Hook (PostToolUse)
# Validates that example files still work after changes to lib/vector_mcp/

# Only run for changes to core library files
if [[ "$TOOL_NAME" == "Edit" || "$TOOL_NAME" == "MultiEdit" || "$TOOL_NAME" == "Write" ]]; then
  file_path=$(echo "$TOOL_INPUT" | jq -r '.file_path // empty')
  
  # Only validate examples when core library files change
  if [[ "$file_path" == lib/vector_mcp/* && "$file_path" == *.rb ]]; then
    echo "🔍 Validating example files after changes to $file_path..."
    
    validation_failed=false
    
    # Check syntax of all example files
    for example in examples/*.rb; do
      if [[ -f "$example" ]]; then
        echo "  Checking syntax: $(basename "$example")"
        if ! ruby -c "$example" >/dev/null 2>&1; then
          echo "  ❌ Syntax error in $example"
          validation_failed=true
        else
          echo "  ✅ $(basename "$example") syntax OK"
        fi
      fi
    done
    
    # Quick require test (load library without executing examples)
    echo "  Checking library load compatibility..."
    if ruby -e "require_relative 'lib/vector_mcp'" >/dev/null 2>&1; then
      echo "  ✅ Library loads successfully"
    else
      echo "  ❌ Library failed to load - examples may not work"
      validation_failed=true
    fi
    
    # Check for missing require statements in examples
    echo "  Checking require statements in examples..."
    for example in examples/*.rb; do
      if [[ -f "$example" ]]; then
        # Check if example requires the main library
        if ! grep -q "require.*vector_mcp" "$example"; then
          echo "  ⚠️  $(basename "$example") may be missing 'require' statement"
        fi
      fi
    done
    
    if [[ "$validation_failed" == "true" ]]; then
      echo "❌ Example validation failed - please check examples after your changes"
    else
      echo "✅ All examples validated successfully"
    fi
  fi
fi