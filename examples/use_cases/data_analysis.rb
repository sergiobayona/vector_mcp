#!/usr/bin/env ruby
# frozen_string_literal: true

# Data Analysis Use Case Example
# Demonstrates AI-assisted data processing and analysis with VectorMCP
#
# This example shows how to:
# - Load and validate datasets from multiple sources
# - Perform statistical analysis and correlation detection
# - Generate visualizations and reports
# - Export results in various formats
# - Integrate with external APIs for data enrichment

require_relative "../../../lib/vector_mcp"
require "json"
require "csv"
require "yaml"

class DataAnalysisServer
  def initialize
    @server = VectorMCP::Server.new("DataAnalysis")
    @datasets = {}
    configure_logging
    setup_workspace
    register_data_tools
    register_analysis_tools
    register_export_tools
    register_visualization_tools
  end

  def run
    puts "📊 VectorMCP Data Analysis Server"
    puts "🔍 AI-assisted data processing and insights"
    puts "📈 Statistical analysis and visualization"
    puts
    puts "🚀 Server starting on stdio transport..."
    puts "💡 Try calling tools like 'load_dataset', 'analyze_data', or 'generate_report'"
    puts

    @server.run(transport: :stdio)
  end

  private

  def configure_logging

# Run the server
if __FILE__ == $PROGRAM_NAME
  server = DataAnalysisServer.new
  server.run
end
