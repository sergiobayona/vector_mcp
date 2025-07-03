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

### 3. Version Comparison Check

**CRITICAL**: Compare local version against published gem version to prevent conflicts:

```bash
# Check current local version
!grep -n "VERSION" lib/vector_mcp/version.rb

# Check latest published version on RubyGems
!gem list vector_mcp --remote --exact

# Alternative: Check specific version info
!gem query --remote --exact --name vector_mcp
```

**Version Analysis:**
- If local version matches published version → Need to bump version
- If local version is newer → Ready for release (verify changelog)
- If local version is older → Update to appropriate new version

### 4. Documentation Review

**CRITICAL**: Verify README.md reflects all new features since last release:

```bash
# Check commits since last published version tag
!git log --oneline $(git describe --tags --abbrev=0)..HEAD

# Review README.md for feature completeness
!grep -n "## Features\|### Features\|## What's New" README.md
```

**README.md Review Checklist:**
- [ ] All new features from commits are documented
- [ ] Installation instructions are current
- [ ] Usage examples reflect new capabilities
- [ ] API documentation matches current version
- [ ] Breaking changes are clearly noted
- [ ] Links and references are working

**Common README.md Sections to Update:**
- Features list
- Installation/Setup instructions
- Usage examples and code samples
- API documentation
- Breaking changes section
- Known issues or limitations

### 5. Run Full Test Suite

Ensure all tests pass before release:

```bash
!bundle exec rake
```

This runs the default task which includes:
- RSpec test suite
- RuboCop linting and style checks

### 6. Generate Documentation

Update the documentation:

```bash
!bundle exec rake yard
```

### 7. Version Update

Now you need to:

1. **Update the version** in `lib/vector_mcp/version.rb`
2. **Update CHANGELOG.md** with the new version and release notes

Current version is displayed above from step 3.

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

### 8. Build and Test the Gem

Build the gem locally to ensure it packages correctly:

```bash
!gem build vector_mcp.gemspec
```

### 9. Commit Release Changes

Commit the version and changelog updates:

```bash
!git add lib/vector_mcp/version.rb CHANGELOG.md README.md
!git commit -m "Release version X.Y.Z

- Update version to X.Y.Z
- Update CHANGELOG.md with release notes
- Update README.md with new features"
```

### 10. Create Git Tag

Create a version tag:

```bash
!git tag -a vX.Y.Z -m "Release version X.Y.Z"
```

### 11. Push to Repository

Push the changes and tags to the repository:

```bash
!git push origin main
!git push origin vX.Y.Z
```

### 12. Release to RubyGems

**IMPORTANT:** This step publishes the gem publicly. Make sure you're ready!

```bash
!gem push vector_mcp-X.Y.Z.gem
```

### 13. Verify Release

Check that the gem was published successfully:

```bash
!gem list vector_mcp --remote --exact
```

### 14. Clean Up

Remove the local gem file:

```bash
!rm vector_mcp-*.gem
```

## Post-Release Checklist

- [ ] Verify gem is available on RubyGems.org
- [ ] Check that GitHub release was created (if using GitHub Actions)
- [ ] Update any dependent projects
- [ ] Announce the release (if applicable)

## Version Conflict Prevention

**Before Any Release:**
1. Always check published version first
2. Ensure local version is properly incremented
3. Verify no version conflicts exist
4. Double-check CHANGELOG.md reflects the correct version
5. Verify README.md documents all new features since last release

**Common Issues:**
- **Same Version**: Local version matches published → Increment version number
- **Lower Version**: Local version is older → Update to appropriate new version
- **Version Gaps**: Missing intermediate versions → Consider if gap is intentional

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

**Version conflicts:**
- Check published versions: `gem list vector_mcp --remote --all`
- Verify local version is appropriate: `grep VERSION lib/vector_mcp/version.rb`
- Ensure version follows semantic versioning

**RubyGems push fails:**
- Verify you're authenticated: `gem signin`
- Check network connectivity and RubyGems status
- Ensure the version doesn't already exist
- Verify version format is correct (no leading 'v')

**Permission denied:**
- Verify you have push permissions to the gem
- Check that MFA is properly configured