# Claude Code Hooks for VectorMCP

This directory contains comprehensive Claude Code hooks that enhance development workflow, security, and code quality for the VectorMCP Ruby gem project.

## Hook Overview

### 🔧 Code Quality & Automation
- **`rubocop-auto-fix.sh`** (PostToolUse): Automatically runs RuboCop style corrections after Ruby file edits
- **`run-tests.sh`** (PostToolUse): Runs relevant tests after changes to `lib/vector_mcp/` files
- **`validate-examples.sh`** (PostToolUse): Validates example files still work after library changes

### 🛡️ Security & Protection
- **`security-check.sh`** (PreToolUse): Blocks access to sensitive files and validates commands
- **`security-logger.sh`** (All hooks): Comprehensive audit logging for security compliance
- **`branch-protection.sh`** (PreToolUse): Prevents risky operations on main branch

### 📊 Monitoring & Analysis
- **`performance-monitor.sh`** (PostToolUse): Tracks performance of tests, builds, and file operations
- **`dependency-tracker.sh`** (PostToolUse): Monitors new dependencies and API changes
- **`version-check.sh`** (PreToolUse): Ensures version consistency and provides release reminders

## Installation & Configuration

### 1. Claude Code Settings

Add to your Claude Code settings file (usually `~/.claude/settings.json`):

```json
{
  "hooks": {
    "PreToolUse": [
      ".claude/hooks/security-check.sh",
      ".claude/hooks/version-check.sh",
      ".claude/hooks/branch-protection.sh"
    ],
    "PostToolUse": [
      ".claude/hooks/rubocop-auto-fix.sh",
      ".claude/hooks/run-tests.sh",
      ".claude/hooks/validate-examples.sh",
      ".claude/hooks/dependency-tracker.sh",
      ".claude/hooks/performance-monitor.sh"
    ],
    "Notification": [
      ".claude/hooks/security-logger.sh"
    ],
    "Stop": [
      ".claude/hooks/security-logger.sh"
    ]
  }
}
```

### 2. Make Hooks Executable

All hooks are already executable, but if needed:

```bash
chmod +x .claude/hooks/*.sh
```

### 3. Log Directory Setup

Hooks will automatically create log directories, but you can pre-create them:

```bash
mkdir -p ~/.claude/logs
```

## Hook Details

### 🔧 `rubocop-auto-fix.sh`
**Trigger**: After editing Ruby files  
**Action**: Runs `rubocop --auto-correct` for safe style fixes  
**Benefits**: Maintains consistent code style automatically

### 🧪 `run-tests.sh`
**Trigger**: After editing files in `lib/vector_mcp/`  
**Action**: Runs corresponding spec files or component tests  
**Benefits**: Immediate feedback on code changes, catches regressions early

### 🔍 `validate-examples.sh`
**Trigger**: After editing core library files  
**Action**: Checks syntax and library compatibility of example files  
**Benefits**: Ensures examples stay current with API changes

### 🚫 `security-check.sh`
**Trigger**: Before file access or bash commands  
**Action**: Blocks sensitive file access, validates commands  
**Benefits**: Prevents accidental exposure of secrets or credentials

### 📝 `security-logger.sh`
**Trigger**: All hook events  
**Action**: Comprehensive audit logging to `~/.claude/logs/vectormcp-audit.log`  
**Benefits**: Complete audit trail for security and compliance

### 🌟 `branch-protection.sh`
**Trigger**: Before file operations  
**Action**: Warns about main branch edits, suggests feature branches  
**Benefits**: Encourages best practices for git workflow

### ⏱️ `performance-monitor.sh`
**Trigger**: After bash commands and file operations  
**Action**: Logs performance metrics to `~/.claude/logs/performance.log`  
**Benefits**: Tracks test execution times and identifies bottlenecks

### 📦 `dependency-tracker.sh`
**Trigger**: After editing Ruby files  
**Action**: Detects new dependencies and API changes  
**Benefits**: Reminds to update Gemfile and documentation

### 🔢 `version-check.sh`
**Trigger**: Before editing version-related files  
**Action**: Provides version consistency checks and release reminders  
**Benefits**: Prevents version conflicts and ensures proper release process

## Log Files

### Audit Log (`~/.claude/logs/vectormcp-audit.log`)
- All tool usage with timestamps
- User and git context
- Security events and warnings
- Automatic rotation when >10MB

### Performance Log (`~/.claude/logs/performance.log`)
- Test execution times
- RuboCop performance
- Bundle operation timing
- Large file operation tracking

## Customization

### Disabling Specific Hooks

To disable a hook, remove it from your settings file or rename the file:

```bash
mv .claude/hooks/hook-name.sh .claude/hooks/hook-name.sh.disabled
```

### Modifying Hook Behavior

Edit the shell scripts directly. Common customizations:

- **Adjust file size thresholds** in `performance-monitor.sh`
- **Add custom security patterns** in `security-check.sh`
- **Modify test execution scope** in `run-tests.sh`
- **Customize logging levels** in `security-logger.sh`

### Environment Variables

Some hooks respect environment variables:

- `CLAUDE_SESSION_ID`: Logged in audit trail
- `VECTORMCP_LOG_LEVEL`: Can influence hook verbosity

## Troubleshooting

### Hook Not Executing
1. Check file permissions: `ls -la .claude/hooks/`
2. Verify settings file syntax: JSON must be valid
3. Check Claude Code logs for hook errors

### Performance Issues
1. Large log files: Logs auto-rotate, but you can manually clean
2. Slow test execution: Modify `run-tests.sh` to run fewer tests
3. Hook timeouts: Consider simplifying complex hooks

### Permission Errors
1. Ensure hooks are executable: `chmod +x .claude/hooks/*.sh`
2. Check log directory permissions: `mkdir -p ~/.claude/logs`
3. Verify git repository access: hooks need git commands to work

## Security Considerations

### Trusted Environment
- Hooks execute with full user permissions
- Only use in trusted development environments
- Review all hook code before enabling

### Log Security
- Audit logs may contain sensitive information
- Rotate logs regularly in production environments
- Consider encrypting logs for compliance requirements

### Network Access
- Some hooks check remote gem versions
- Ensure network access is available for version checks
- Consider offline mode for sensitive environments

## Integration with VectorMCP Development

### Release Process
- Version hooks integrate with `/release` command
- Automatic README verification during releases
- Branch protection prevents accidental main branch releases

### Code Quality
- RuboCop integration maintains style consistency
- Test automation provides immediate feedback
- Example validation ensures documentation accuracy

### Security Compliance
- Comprehensive audit trail for all activities
- Prevention of sensitive file access
- Command validation for risky operations

## Contributing

To add new hooks:

1. Create executable shell script in `.claude/hooks/`
2. Follow naming convention: `feature-name.sh`
3. Add appropriate shebang: `#!/bin/bash`
4. Use consistent logging format
5. Update this README with hook description
6. Test thoroughly before committing

For hook improvements, consider:
- Performance impact on development workflow
- Security implications of new functionality
- Compatibility across different development environments
- Integration with existing VectorMCP tools and processes