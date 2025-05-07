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
end

desc "Generate YARD documentation"
task doc: :yard

task default: %i[spec rubocop]
