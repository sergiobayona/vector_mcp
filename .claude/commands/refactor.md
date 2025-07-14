---
allowed-tools: Edit, MultiEdit, Bash(bundle exec rspec:*), Bash(bundle exec rubocop:*)
description: Refactor Ruby code while maintaining functionality
---

# Ruby Code Refactoring

Refactor the following Ruby code: $ARGUMENTS

## Refactoring Goals:
- Improve readability and maintainability
- Follow Ruby idioms and best practices
- Reduce complexity and duplication
- Maintain existing functionality
- Ensure all tests still pass

## Steps:
1. Read and understand current implementation: @$ARGUMENTS
2. Identify refactoring opportunities
3. Apply refactoring incrementally
4. Run tests after each change: `bundle exec rspec`
5. Check code style: `bundle exec rubocop $ARGUMENTS`

## Project patterns to follow:
@.rubocop.yml