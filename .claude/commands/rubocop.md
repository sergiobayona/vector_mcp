# RuboCop Fix All Offenses

Comprehensive workflow for running RuboCop and systematically fixing all style and linting offenses in the VectorMCP Ruby gem.

## Overview

This command runs RuboCop to identify all linting and style issues, then systematically fixes them using both automatic fixes and manual corrections where needed.

## Steps

### 1. Pre-check: Git Status

Ensure we're starting from a clean state:

```bash
!git status --porcelain
```

If there are uncommitted changes, commit or stash them first to isolate RuboCop fixes.

### 2. Initial RuboCop Analysis

Run RuboCop to see current state of offenses:

```bash
# Get overview of all offenses
!bundle exec rubocop --format progress

# Get detailed offense breakdown by cop
!bundle exec rubocop --format offenses
```

**Analyze the output:**
- Note total offense count
- Identify most common offense types
- Look for auto-correctable offenses

### 3. Auto-correct Safe Offenses

Fix all safe auto-correctable offenses first:

```bash
# Auto-correct safe offenses only
!bundle exec rubocop --auto-correct

# Check remaining offenses after safe corrections
!bundle exec rubocop --format progress
```

### 4. Auto-correct Unsafe Offenses (with caution)

Fix unsafe auto-correctable offenses (review changes carefully):

```bash
# Auto-correct unsafe offenses (be careful!)
!bundle exec rubocop --auto-correct-all

# Immediately check what changed
!git diff
```

**⚠️ IMPORTANT**: Review all changes from unsafe auto-corrections before proceeding.

### 5. Run Tests After Auto-corrections

Ensure auto-corrections didn't break anything:

```bash
!bundle exec rspec
```

If tests fail, investigate and fix issues before continuing.

### 6. Manual Fix Remaining Offenses

Address remaining offenses that require manual intervention:

```bash
# Show remaining offenses with file locations
!bundle exec rubocop --format simple

# For specific files with many offenses, focus on one file at a time
!bundle exec rubocop lib/vector_mcp/specific_file.rb --format simple
```

**Common Manual Fixes:**
- **Line Length**: Break long lines appropriately
- **Method Length**: Extract methods or refactor complex logic
- **Class Length**: Split large classes into multiple files
- **Complexity**: Simplify complex methods
- **Documentation**: Add missing method/class documentation

### 7. Iterative Fixing Process

For each remaining offense:

1. **Identify the file and line**: `file_path:line_number`
2. **Read the offense description**: Understand what needs fixing
3. **Fix the issue**: Make appropriate code changes
4. **Verify the fix**: Run RuboCop on the specific file
5. **Run tests**: Ensure fix doesn't break functionality

```bash
# Check specific file after fixing
!bundle exec rubocop lib/vector_mcp/specific_file.rb

# Run tests for the specific area you changed
!bundle exec rspec spec/vector_mcp/specific_file_spec.rb
```

### 8. Final Verification

Once all manual fixes are complete:

```bash
# Verify no offenses remain
!bundle exec rubocop

# Run full test suite to ensure nothing is broken
!bundle exec rake

# Check git status to see all changes
!git status
```

### 9. Commit RuboCop Fixes

Commit all the linting fixes:

```bash
!git add .
!git commit -m "Fix all RuboCop offenses

- Auto-correct safe and unsafe offenses
- Manual fixes for remaining style issues
- Ensure all tests pass

🤖 Generated with [Claude Code](https://claude.ai/code)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

## Common RuboCop Offense Categories

### Auto-correctable Offenses
- **Layout/TrailingWhitespace**: Extra spaces at end of lines
- **Style/StringLiterals**: Quote style consistency
- **Layout/EmptyLines**: Extra or missing empty lines
- **Style/FrozenStringLiteralComment**: Missing frozen string literal comments
- **Layout/IndentationWidth**: Inconsistent indentation

### Manual Fix Required
- **Metrics/MethodLength**: Methods too long (need refactoring)
- **Metrics/ClassLength**: Classes too long (need splitting)
- **Metrics/CyclomaticComplexity**: Complex methods (need simplification)
- **Style/Documentation**: Missing class/module documentation
- **Naming/MethodName**: Poor method naming

## Troubleshooting

**RuboCop command not found:**
```bash
!bundle install
!bundle exec rubocop --version
```

**Too many offenses to fix at once:**
```bash
# Fix one cop type at a time
!bundle exec rubocop --only Layout/TrailingWhitespace --auto-correct
!bundle exec rubocop --only Style/StringLiterals --auto-correct
```

**Tests failing after auto-corrections:**
- Review the diff carefully: `!git diff`
- Run specific test files to isolate issues
- Revert problematic changes if needed: `!git checkout -- problematic_file.rb`

**Large refactoring needed:**
- Create separate commits for large changes
- Use TODO comments for complex refactoring that can't be done immediately
- Consider creating issues for major refactoring work

## Configuration Notes

RuboCop configuration is in `.rubocop.yml`. Common adjustments:

- **Metrics/MethodLength**: Adjust `Max` if needed for your codebase
- **Style/Documentation**: Can be disabled for internal classes
- **Layout/LineLength**: Adjust `Max` for your team's preferences

## Best Practices

1. **Incremental Approach**: Fix offenses in small, logical groups
2. **Test Frequently**: Run tests after each group of fixes
3. **Review Changes**: Always review auto-corrections before committing
4. **Consistent Style**: Maintain consistency with existing codebase patterns
5. **Document Decisions**: Update `.rubocop.yml` for intentional style choices

## Post-Fix Maintenance

- Run RuboCop in CI to prevent future offenses
- Consider pre-commit hooks for automatic style checking
- Regular team discussions about style preferences
- Keep RuboCop version updated for latest best practices