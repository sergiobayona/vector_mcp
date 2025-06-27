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
    @logger = VectorMCP.logger_for("data_analysis")
  end

  def setup_workspace
    @workspace_dir = File.join(__dir__, "data_workspace")
    Dir.mkdir(@workspace_dir) unless Dir.exist?(@workspace_dir)
    @server.register_root_from_path(@workspace_dir, name: "Data Workspace")
  end

  def register_data_tools
    # Tool to load datasets from various sources
    @server.register_tool(
      name: "load_dataset",
      description: "Load a dataset from CSV, JSON, or YAML file",
      input_schema: {
        type: "object",
        properties: {
          file_path: { type: "string", description: "Path to the data file" },
          dataset_name: { type: "string", description: "Name to identify this dataset" },
          format: { type: "string", enum: ["csv", "json", "yaml"], description: "File format" }
        },
        required: ["file_path", "dataset_name", "format"]
      }
    ) do |args, session|
      file_path = args["file_path"]
      dataset_name = args["dataset_name"]
      format = args["format"]

      @logger.info("Loading dataset", dataset: dataset_name, path: file_path, format: format)

      begin
        data = case format
               when "csv"
                 CSV.read(file_path, headers: true).map(&:to_h)
               when "json"
                 JSON.parse(File.read(file_path))
               when "yaml"
                 YAML.load_file(file_path)
               end

        @datasets[dataset_name] = {
          data: data,
          loaded_at: Time.now,
          source: file_path,
          format: format,
          rows: data.is_a?(Array) ? data.size : 1
        }

        {
          status: "success",
          dataset: dataset_name,
          rows_loaded: @datasets[dataset_name][:rows],
          sample: data.is_a?(Array) ? data.first(3) : data
        }
      rescue => e
        @logger.error("Failed to load dataset", error: e.message, dataset: dataset_name)
        { status: "error", error: e.message }
      end
    end

    # Tool to list available datasets
    @server.register_tool(
      name: "list_datasets",
      description: "List all loaded datasets",
      input_schema: { type: "object", properties: {} }
    ) do |args, session|
      {
        datasets: @datasets.keys,
        details: @datasets.transform_values do |info|
          info.except(:data)
        end
      }
    end
  end

  def register_analysis_tools
    # Statistical analysis tool
    @server.register_tool(
      name: "analyze_data",
      description: "Perform statistical analysis on a dataset",
      input_schema: {
        type: "object",
        properties: {
          dataset_name: { type: "string", description: "Name of the dataset to analyze" },
          columns: { type: "array", items: { type: "string" }, description: "Columns to analyze (optional)" },
          analysis_type: { type: "string", enum: ["summary", "correlation", "distribution"], description: "Type of analysis" }
        },
        required: ["dataset_name", "analysis_type"]
      }
    ) do |args, session|
      dataset_name = args["dataset_name"]
      analysis_type = args["analysis_type"]
      columns = args["columns"]

      dataset = @datasets[dataset_name]
      return { status: "error", error: "Dataset '#{dataset_name}' not found" } unless dataset

      data = dataset[:data]
      @logger.info("Analyzing dataset", dataset: dataset_name, type: analysis_type)

      case analysis_type
      when "summary"
        analyze_summary(data, columns)
      when "correlation"
        analyze_correlation(data, columns)
      when "distribution"
        analyze_distribution(data, columns)
      end
    end

    # Data filtering tool
    @server.register_tool(
      name: "filter_data",
      description: "Filter dataset based on conditions",
      input_schema: {
        type: "object",
        properties: {
          dataset_name: { type: "string", description: "Name of the dataset to filter" },
          conditions: { type: "object", description: "Filter conditions as key-value pairs" },
          save_as: { type: "string", description: "Name for the filtered dataset" }
        },
        required: ["dataset_name", "conditions"]
      }
    ) do |args, session|
      dataset_name = args["dataset_name"]
      conditions = args["conditions"]
      save_as = args["save_as"] || "#{dataset_name}_filtered"

      dataset = @datasets[dataset_name]
      return { status: "error", error: "Dataset '#{dataset_name}' not found" } unless dataset

      data = dataset[:data]
      filtered_data = data.select do |row|
        conditions.all? { |key, value| row[key] == value }
      end

      if save_as
        @datasets[save_as] = dataset.merge(
          data: filtered_data,
          rows: filtered_data.size,
          filtered_from: dataset_name
        )
      end

      {
        status: "success",
        original_rows: data.size,
        filtered_rows: filtered_data.size,
        saved_as: save_as,
        sample: filtered_data.first(3)
      }
    end
  end

  def register_export_tools
    # Export tool
    @server.register_tool(
      name: "export_data",
      description: "Export dataset to various formats",
      input_schema: {
        type: "object",
        properties: {
          dataset_name: { type: "string", description: "Name of the dataset to export" },
          format: { type: "string", enum: ["csv", "json", "yaml"], description: "Export format" },
          filename: { type: "string", description: "Output filename" }
        },
        required: ["dataset_name", "format", "filename"]
      }
    ) do |args, session|
      dataset_name = args["dataset_name"]
      format = args["format"]
      filename = args["filename"]

      dataset = @datasets[dataset_name]
      return { status: "error", error: "Dataset '#{dataset_name}' not found" } unless dataset

      output_path = File.join(@workspace_dir, filename)
      data = dataset[:data]

      begin
        case format
        when "csv"
          CSV.open(output_path, "w", write_headers: true, headers: data.first.keys) do |csv|
            data.each { |row| csv << row.values }
          end
        when "json"
          File.write(output_path, JSON.pretty_generate(data))
        when "yaml"
          File.write(output_path, data.to_yaml)
        end

        {
          status: "success",
          exported_file: output_path,
          rows_exported: data.size,
          format: format
        }
      rescue => e
        { status: "error", error: e.message }
      end
    end
  end

  def register_visualization_tools
    # Simple visualization tool
    @server.register_tool(
      name: "generate_report",
      description: "Generate a summary report for a dataset",
      input_schema: {
        type: "object",
        properties: {
          dataset_name: { type: "string", description: "Name of the dataset" },
          include_sample: { type: "boolean", description: "Include data sample in report", default: true }
        },
        required: ["dataset_name"]
      }
    ) do |args, session|
      dataset_name = args["dataset_name"]
      include_sample = args.fetch("include_sample", true)

      dataset = @datasets[dataset_name]
      return { status: "error", error: "Dataset '#{dataset_name}' not found" } unless dataset

      data = dataset[:data]
      report = {
        dataset_name: dataset_name,
        source: dataset[:source],
        loaded_at: dataset[:loaded_at],
        total_rows: dataset[:rows],
        columns: data.first&.keys || [],
        column_count: data.first&.keys&.size || 0
      }

      if include_sample
        report[:sample_data] = data.first(5)
      end

      report
    end
  end

  def analyze_summary(data, columns = nil)
    return { status: "error", error: "No data to analyze" } if data.empty?

    cols = columns || data.first.keys
    numeric_cols = cols.select do |col|
      data.all? { |row| row[col].is_a?(Numeric) }
    end

    summary = {}
    
    cols.each do |col|
      values = data.map { |row| row[col] }
      unique_values = values.uniq

      col_summary = {
        total_values: values.size,
        unique_values: unique_values.size,
        null_values: values.count(nil)
      }

      if numeric_cols.include?(col)
        numeric_values = values.compact
        if numeric_values.any?
          col_summary.merge!(
            min: numeric_values.min,
            max: numeric_values.max,
            mean: numeric_values.sum.to_f / numeric_values.size,
            median: numeric_values.sort[numeric_values.size / 2]
          )
        end
      else
        col_summary[:most_common] = unique_values.first(5)
      end

      summary[col] = col_summary
    end

    { status: "success", summary: summary }
  end

  def analyze_correlation(data, columns = nil)
    numeric_cols = (columns || data.first.keys).select do |col|
      data.all? { |row| row[col].is_a?(Numeric) }
    end

    return { status: "error", error: "No numeric columns found for correlation" } if numeric_cols.size < 2

    correlations = {}
    numeric_cols.combination(2) do |col1, col2|
      values1 = data.map { |row| row[col1].to_f }
      values2 = data.map { |row| row[col2].to_f }
      
      # Simple Pearson correlation coefficient
      mean1 = values1.sum / values1.size
      mean2 = values2.sum / values2.size
      
      numerator = values1.zip(values2).sum { |v1, v2| (v1 - mean1) * (v2 - mean2) }
      denominator = Math.sqrt(
        values1.sum { |v1| (v1 - mean1) ** 2 } *
        values2.sum { |v2| (v2 - mean2) ** 2 }
      )
      
      correlation = denominator.zero? ? 0 : numerator / denominator
      correlations["#{col1}_vs_#{col2}"] = correlation.round(4)
    end

    { status: "success", correlations: correlations }
  end

  def analyze_distribution(data, columns = nil)
    cols = columns || data.first.keys
    distributions = {}

    cols.each do |col|
      values = data.map { |row| row[col] }
      frequency = values.each_with_object(Hash.new(0)) { |value, hash| hash[value] += 1 }
      
      distributions[col] = {
        frequency: frequency.sort_by { |k, v| -v }.first(10).to_h,
        total_unique: frequency.size
      }
    end

    { status: "success", distributions: distributions }
  end
end

# Run the server
if __FILE__ == $PROGRAM_NAME
  server = DataAnalysisServer.new
  server.run
end
