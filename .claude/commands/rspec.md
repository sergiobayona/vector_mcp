---
allowed-tools: Bash(bundle exec rspec:*), Edit, Write, Read
description: Generate RSpec tests for Ruby classes or methods
---

# RSpec Test Generator

Generate comprehensive RSpec tests for the specified Ruby class or method: $ARGUMENTS

## Requirements:
- Follow RSpec best practices
- Include both positive and negative test cases
- Use proper describe/context/it structure
- Include edge cases and error conditions
- Use appropriate matchers and helpers
- Follow the project's existing test patterns

## Current test structure:
!`find spec -name "*.rb" | head -5 | xargs ls -la`

## Project's RSpec configuration:
@spec/spec_helper.rb
