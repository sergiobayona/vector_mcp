# frozen_string_literal: true

# Sets up an in-memory SQLite database with a minimal schema and a few
# ActiveRecord models, for specs that exercise VectorMCP::Rails::Tool.
#
# Guarded on ActiveRecord being present so environments without AR (the
# core gem has no runtime AR dep) silently skip. Tests that rely on this
# support file must also guard themselves with `if defined?(ActiveRecord)`.

require "active_record"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")

ActiveRecord::Schema.define do
  self.verbose = false

  create_table :widgets, force: true do |t|
    t.string :name, null: false
    t.integer :quantity, default: 0
    t.timestamps
  end
end

# Test models live under a dedicated module so they don't pollute the
# top-level namespace and can't collide with real app models.
module VectorMCPRailsToolTestModels
  class Widget < ActiveRecord::Base
    self.table_name = "widgets"
    validates :name, presence: true
    validates :quantity, numericality: { greater_than_or_equal_to: 0 }
  end
end

RSpec.configure do |config|
  config.before(:each, :active_record) do
    VectorMCPRailsToolTestModels::Widget.delete_all
  end
end
