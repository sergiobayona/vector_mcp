# Release Workflow

Comprehensive workflow for releasing a new version of the VectorMCP Ruby gem following best practices.

## Overview

This command guides you through the complete release process for the VectorMCP gem, ensuring all steps are followed correctly and the release is done safely from a clean state.

## Steps

### 1. Pre-release Checks

First, let's verify we're in a clean state and on the main branch:

```bash
!git status --porcelain
!git branch --show-current
```

If there are uncommitted changes, you should commit or stash them first.
If you're not on the main branch, switch to it: `git checkout main`

### 2. Update from Remote

Ensure we have the latest changes from the remote repository:

```bash
!git pull origin main
```

### 3. Version Information

Current version information:

```bash
!grep -n "VERSION" lib/vector_mcp/version.rb
```

### 4. Run Full Test Suite

Ensure all tests pass before release:

```bash
!bundle exec rake
```

This runs the default task which includes:
- RSpec test suite
- RuboCop linting and style checks

### 5. Generate Documentation

Update the documentation:

```bash
!bundle exec rake yard
```

### 6. Version Update

Now you need to:

1. **Update the version** in `lib/vector_mcp/version.rb`
2. **Update CHANGELOG.md** with the new version and release notes

Current version is: `@lib/vector_mcp/version.rb`

**Version Update Guidelines:**
- **Patch** (0.3.2 → 0.3.3): Bug fixes, security patches
- **Minor** (0.3.2 → 0.4.0): New features, backward-compatible changes
- **Major** (0.3.2 → 1.0.0): Breaking changes, major rewrites

**CHANGELOG.md Format:**
```markdown
## [X.Y.Z] – YYYY-MM-DD

### Added
- New features

### Changed
- Modifications to existing features

### Fixed
- Bug fixes

### Security
- Security improvements
```

### 7. Build and Test the Gem

Build the gem locally to ensure it packages correctly:

```bash
!gem build vector_mcp.gemspec
```

### 8. Commit Release Changes

Commit the version and changelog updates:

```bash
!git add lib/vector_mcp/version.rb CHANGELOG.md
!git commit -m "Release version X.Y.Z

- Update version to X.Y.Z
- Update CHANGELOG.md with release notes"
```

### 9. Create Git Tag

Create a version tag:

```bash
!git tag -a vX.Y.Z -m "Release version X.Y.Z"
```

### 10. Push to Repository

Push the changes and tags to the repository:

```bash
!git push origin main
!git push origin vX.Y.Z
```

### 11. Release to RubyGems

**IMPORTANT:** This step publishes the gem publicly. Make sure you're ready!

```bash
!gem push vector_mcp-X.Y.Z.gem
```

### 12. Verify Release

Check that the gem was published successfully:

```bash
!gem list vector_mcp --remote --exact
```

### 13. Clean Up

Remove the local gem file:

```bash
!rm vector_mcp-*.gem
```

## Post-Release Checklist

- [ ] Verify gem is available on RubyGems.org
- [ ] Check that GitHub release was created (if using GitHub Actions)
- [ ] Update any dependent projects
- [ ] Announce the release (if applicable)

## Rollback Procedure

If you need to rollback a release:

1. **Remove the tag:**
   ```bash
   git tag -d vX.Y.Z
   git push origin :refs/tags/vX.Y.Z
   ```

2. **Yank the gem from RubyGems:**
   ```bash
   gem yank vector_mcp -v X.Y.Z
   ```

3. **Revert version changes:**
   ```bash
   git revert <commit-hash>
   ```

## Security Notes

- The gemspec includes `metadata["rubygems_mfa_required"] = "true"` for enhanced security
- Ensure your RubyGems account has MFA enabled
- Never commit API keys or sensitive information

## Troubleshooting

**Build fails:**
- Ensure all dependencies are installed: `bundle install`
- Check for syntax errors: `ruby -c lib/vector_mcp.rb`

**Tests fail:**
- Run tests individually to identify issues: `bundle exec rspec spec/path/to/specific_spec.rb`
- Check for missing dependencies or configuration issues

**RubyGems push fails:**
- Verify you're authenticated: `gem signin`
- Check network connectivity and RubyGems status
- Ensure the version doesn't already exist

**Permission denied:**
- Verify you have push permissions to the gem
- Check that MFA is properly configured