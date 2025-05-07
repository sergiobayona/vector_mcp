# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

require "rubocop/rake_task"

RuboCop::RakeTask.new

# YARD documentation generation task
require "yard"
require "yard/rake/yardoc_task"

YARD::Rake::YardocTask.new(:yard) do |t|
  # Generate docs into the `doc` folder so GitHub Pages can host them
  t.options = ["--output-dir", "doc"]

  # Restrict the set of files that YARD parses. By default YARD will look at
  # every Ruby file it can find starting at the current working directory. On
  # macOS this can cause "Operation not permitted" errors when it traverses
  # protected locations such as
  #   /Library/Application Support/com.apple.TCC
  # unless the invoking process has *Full Disk Access*.
  #
  # Explicitly listing the project files keeps YARD inside the repo and avoids
  # those permission errors without requiring developers to grant extra macOS
  # privileges.
  t.files = [
    "lib/**/*.rb",
    "README.md",
    "LICENSE.txt",
    "CHANGELOG.md"
  ]
end

desc "Generate YARD documentation"
task doc: :yard

task default: %i[spec rubocop]
