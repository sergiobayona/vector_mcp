#!/bin/bash
# Version Consistency Check Hook (PreToolUse)
# Ensures version consistency across files and provides release reminders

# Only check for version file modifications
if [[ "$TOOL_NAME" == "Edit" || "$TOOL_NAME" == "Write" ]]; then
  file_path=$(echo "$TOOL_INPUT" | jq -r '.file_path // ""')
  
  # Check for version.rb modifications
  if [[ "$file_path" =~ version\.rb$ ]]; then
    echo "🔢 Version file modification detected: $file_path"
    echo ""
    echo "📋 Version Update Checklist:"
    echo "  □ Update CHANGELOG.md with new version and release notes"
    echo "  □ Update README.md if new features were added"
    echo "  □ Ensure all tests pass with new version"
    echo "  □ Check that version follows semantic versioning"
    echo "  □ Consider updating examples if API changed"
    echo ""
    
    # Check current version in the file
    if [[ -f "$file_path" ]]; then
      current_version=$(grep -E "VERSION\s*=" "$file_path" | sed -E 's/.*VERSION\s*=\s*["\']([^"\']+)["\'].*/\1/')
      if [[ -n "$current_version" ]]; then
        echo "📌 Current version: $current_version"
        
        # Check against published version (if available)
        echo "🔍 Checking published gem version..."
        published_version=$(gem list vector_mcp --remote --exact 2>/dev/null | grep -E "vector_mcp" | sed -E 's/.*\(([^)]+)\).*/\1/' | head -1)
        
        if [[ -n "$published_version" ]]; then
          echo "📦 Published version: $published_version"
          
          # Simple version comparison
          if [[ "$current_version" == "$published_version" ]]; then
            echo "⚠️  WARNING: Current version matches published version!"
            echo "   Consider incrementing the version number before release."
          elif [[ "$current_version" < "$published_version" ]]; then
            echo "⚠️  WARNING: Current version is lower than published version!"
            echo "   This suggests the version was not properly incremented."
          else
            echo "✅ Version is newer than published version"
          fi
        else
          echo "ℹ️  Could not check published version (gem may not be published yet)"
        fi
      fi
    fi
    echo ""
  fi
  
  # Check for CHANGELOG.md modifications
  if [[ "$file_path" =~ CHANGELOG\.md$ ]]; then
    echo "📝 CHANGELOG.md modification detected"
    echo "💡 Reminder: Ensure version in CHANGELOG matches lib/vector_mcp/version.rb"
    
    # Check if version from version.rb is mentioned in changelog
    if [[ -f "lib/vector_mcp/version.rb" ]]; then
      version=$(grep -E "VERSION\s*=" lib/vector_mcp/version.rb | sed -E 's/.*VERSION\s*=\s*["\']([^"\']+)["\'].*/\1/')
      if [[ -n "$version" ]] && [[ -f "$file_path" ]]; then
        if grep -q "$version" "$file_path"; then
          echo "✅ Current version $version found in CHANGELOG"
        else
          echo "⚠️  Current version $version not found in CHANGELOG"
          echo "   Consider adding an entry for this version"
        fi
      fi
    fi
    echo ""
  fi
  
  # Check for gemspec modifications
  if [[ "$file_path" =~ \.gemspec$ ]]; then
    echo "💎 Gemspec modification detected: $file_path"
    echo "📋 Gemspec Update Checklist:"
    echo "  □ Version matches lib/vector_mcp/version.rb"
    echo "  □ Dependencies are up to date"
    echo "  □ Description reflects current functionality"
    echo "  □ Authors and contact info are current"
    echo "  □ Homepage and source URLs are correct"
    echo ""
  fi
fi

# Check for README modifications when library files change
if [[ "$TOOL_NAME" == "Edit" && "$file_path" =~ lib/vector_mcp/ ]]; then
  echo "📚 Library file modified: $file_path"
  echo "💡 Consider updating README.md if public API or features changed"
fi