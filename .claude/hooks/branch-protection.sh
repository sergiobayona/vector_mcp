#!/bin/bash
# Branch Protection Hook (PreToolUse)
# Prevents risky operations on main branch and provides guidance

# Check current branch
current_branch=$(git branch --show-current 2>/dev/null)

# Only proceed if we're in a git repository
if [[ -z "$current_branch" ]]; then
  exit 0  # Not in a git repo, skip checks
fi

# Check for direct edits to main/master branch
if [[ "$current_branch" == "main" || "$current_branch" == "master" ]]; then
  
  # For file operations, warn but allow
  if [[ "$TOOL_NAME" == "Edit" || "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "MultiEdit" ]]; then
    file_path=$(echo "$TOOL_INPUT" | jq -r '.file_path // ""')
    
    # More restrictive for core library files
    if [[ "$file_path" =~ lib/vector_mcp/ ]]; then
      echo "⚠️  WARNING: Editing core library file on $current_branch branch"
      echo "   File: $file_path"
      echo "   Consider creating a feature branch for this change:"
      echo "   git checkout -b feature/your-feature-name"
      echo ""
    
    # Very restrictive for version files
    elif [[ "$file_path" =~ version\.rb$|\.gemspec$ ]]; then
      echo "🚨 CAUTION: Modifying version/release files on $current_branch branch"
      echo "   File: $file_path"
      echo "   This suggests a release. Ensure you're following the release process."
      echo "   Consider using: /release command for guided release workflow"
      echo ""
      
    # General warning for other files
    else
      echo "💡 NOTE: Editing on $current_branch branch: $(basename "$file_path")"
      echo "   For significant changes, consider using a feature branch"
      echo ""
    fi
  fi
  
  # For potentially destructive bash commands, be more restrictive
  if [[ "$TOOL_NAME" == "Bash" ]]; then
    command=$(echo "$TOOL_INPUT" | jq -r '.command // ""')
    
    # Block destructive operations on main branch
    if [[ "$command" =~ (git reset --hard|git rebase|git push --force) ]]; then
      echo "🚫 BLOCKED: Destructive git operation on $current_branch branch"
      echo "   Command: $command"
      echo "   Create a feature branch first: git checkout -b feature/your-feature"
      exit 1
    fi
    
    # Warn about other risky operations
    if [[ "$command" =~ (rm -rf|sudo|mv.*lib/|rm.*lib/) ]]; then
      echo "⚠️  WARNING: Potentially risky command on $current_branch branch"
      echo "   Command: $command"
      echo "   Double-check this is intentional and safe"
      echo ""
    fi
  fi
fi

# Check for uncommitted changes when creating new files
if [[ "$TOOL_NAME" == "Write" && "$current_branch" == "main" ]]; then
  # Check if there are uncommitted changes
  if ! git diff-index --quiet HEAD -- 2>/dev/null; then
    echo "📝 NOTE: You have uncommitted changes on $current_branch"
    echo "   Consider committing or stashing changes before major modifications"
    echo "   git status  # to see changes"
    echo "   git add . && git commit -m 'your message'  # to commit"
    echo ""
  fi
fi

# Suggest feature branch workflow for significant changes
feature_keywords="feat|feature|add|new|implement|refactor|fix|bug"
if [[ "$TOOL_NAME" == "Edit" && "$current_branch" == "main" ]]; then
  file_path=$(echo "$TOOL_INPUT" | jq -r '.file_path // ""')
  
  # If editing multiple files or core functionality, suggest feature branch
  if [[ "$file_path" =~ lib/vector_mcp/(server|transport|security|middleware)/ ]]; then
    echo "💡 TIP: For changes to core components, consider this workflow:"
    echo "   1. git checkout -b feature/$(echo "$file_path" | sed 's|lib/vector_mcp/||' | sed 's|/.*||')-improvements"
    echo "   2. Make your changes"
    echo "   3. git add . && git commit -m 'Improve $(basename "$file_path")'"
    echo "   4. git push -u origin feature/branch-name"
    echo "   5. Create pull request"
    echo ""
  fi
fi

# Check for release-related activities
if [[ "$current_branch" == "main" ]]; then
  if [[ "$TOOL_NAME" == "Edit" && "$file_path" =~ (CHANGELOG\.md|version\.rb|.*\.gemspec) ]]; then
    echo "🚀 RELEASE ACTIVITY DETECTED on $current_branch"
    echo "   Ensure you're following the complete release checklist:"
    echo "   - Run full test suite"
    echo "   - Update documentation"
    echo "   - Verify version consistency"
    echo "   - Consider using: /release command"
    echo ""
  fi
fi