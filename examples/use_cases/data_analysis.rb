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
    VectorMCP.configure_logging do
      level "INFO"
      component "data.analysis", level: "DEBUG"
      component "data.processing", level: "INFO"
    end
  end

  def setup_workspace
    # Create workspace for data files
    current_dir = File.expand_path(".")
    data_dir = File.join(current_dir, "tmp", "data_analysis")
    FileUtils.mkdir_p(data_dir)
    @server.register_root_from_path(data_dir, name: "Data Workspace")

    # Allow access to example data
    examples_data = File.join(current_dir, "examples", "data")
    @server.register_root_from_path(examples_data, name: "Sample Data") if Dir.exist?(examples_data)
  end

  def register_data_tools
    # Load dataset from various sources
    @server.register_tool(
      name: "load_dataset",
      description: "Load dataset from CSV, JSON, or API source",
      input_schema: {
        type: "object",
        properties: {
          source: {
            type: "string",
            description: "Data source: file path, URL, or API endpoint"
          },
          format: {
            type: "string",
            enum: %w[csv json yaml api],
            description: "Data format"
          },
          name: {
            type: "string",
            description: "Dataset name for reference"
          },
          headers: {
            type: "object",
            description: "HTTP headers for API requests"
          },
          options: {
            type: "object",
            description: "Format-specific options (e.g., CSV delimiter)"
          }
        },
        required: %w[source format name],
        additionalProperties: false
      }
    ) do |arguments, _session_context|
      source = arguments["source"]
      format = arguments["format"]
      name = arguments["name"]
      headers = arguments["headers"] || {}
      options = arguments["options"] || {}

      begin
        data = case format
               when "csv"
                 load_csv_data(source, options)
               when "json"
                 load_json_data(source, headers)
               when "yaml"
                 load_yaml_data(source)
               when "api"
                 load_api_data(source, headers, options)
               else
                 raise "Unsupported format: #{format}"
               end

        # Validate and store dataset
        validated_data = validate_dataset(data)
        @datasets[name] = {
          data: validated_data,
          metadata: generate_metadata(validated_data),
          loaded_at: Time.now.iso8601,
          source: source,
          format: format
        }

        {
          success: true,
          dataset_name: name,
          rows: validated_data.size,
          columns: validated_data.first&.keys&.size || 0,
          metadata: @datasets[name][:metadata]
        }
      rescue StandardError => e
        { success: false, error: "Failed to load dataset: #{e.message}" }
      end
    end

    # List available datasets
    @server.register_tool(
      name: "list_datasets",
      description: "List all loaded datasets with metadata",
      input_schema: {
        type: "object",
        additionalProperties: false
      }
    ) do |_arguments, _session_context|
      {
        success: true,
        datasets: @datasets.transform_values do |dataset|
          {
            rows: dataset[:data].size,
            columns: dataset[:data].first&.keys&.size || 0,
            loaded_at: dataset[:loaded_at],
            source: dataset[:source],
            metadata: dataset[:metadata]
          }
        end
      }
    end

    # Preview dataset
    @server.register_tool(
      name: "preview_dataset",
      description: "Get a preview of dataset with sample rows",
      input_schema: {
        type: "object",
        properties: {
          dataset_name: {
            type: "string",
            description: "Name of the dataset to preview"
          },
          rows: {
            type: "integer",
            minimum: 1,
            maximum: 100,
            default: 10,
            description: "Number of rows to preview"
          }
        },
        required: ["dataset_name"],
        additionalProperties: false
      }
    ) do |arguments, _session_context|
      dataset_name = arguments["dataset_name"]
      rows = arguments["rows"] || 10

      dataset = @datasets[dataset_name]
      return { success: false, error: "Dataset not found: #{dataset_name}" } unless dataset

      {
        success: true,
        dataset_name: dataset_name,
        preview: dataset[:data].first(rows),
        total_rows: dataset[:data].size,
        columns: dataset[:data].first&.keys || []
      }
    end
  end

  def register_analysis_tools
    # Statistical analysis
    @server.register_tool(
      name: "analyze_statistics",
      description: "Perform statistical analysis on numeric columns",
      input_schema: {
        type: "object",
        properties: {
          dataset_name: {
            type: "string",
            description: "Name of the dataset to analyze"
          },
          columns: {
            type: "array",
            items: { type: "string" },
            description: "Specific columns to analyze (all numeric if not specified)"
          }
        },
        required: ["dataset_name"],
        additionalProperties: false
      }
    ) do |arguments, _session_context|
      dataset_name = arguments["dataset_name"]
      specific_columns = arguments["columns"]

      dataset = @datasets[dataset_name]
      return { success: false, error: "Dataset not found: #{dataset_name}" } unless dataset

      begin
        analysis = perform_statistical_analysis(dataset[:data], specific_columns)

        {
          success: true,
          dataset_name: dataset_name,
          analysis: analysis,
          analyzed_at: Time.now.iso8601
        }
      rescue StandardError => e
        { success: false, error: "Analysis failed: #{e.message}" }
      end
    end

    # Correlation analysis
    @server.register_tool(
      name: "analyze_correlations",
      description: "Find correlations between numeric columns",
      input_schema: {
        type: "object",
        properties: {
          dataset_name: {
            type: "string",
            description: "Name of the dataset to analyze"
          },
          threshold: {
            type: "number",
            minimum: 0,
            maximum: 1,
            default: 0.3,
            description: "Minimum correlation threshold"
          }
        },
        required: ["dataset_name"],
        additionalProperties: false
      }
    ) do |arguments, _session_context|
      dataset_name = arguments["dataset_name"]
      threshold = arguments["threshold"] || 0.3

      dataset = @datasets[dataset_name]
      return { success: false, error: "Dataset not found: #{dataset_name}" } unless dataset

      begin
        correlations = find_correlations(dataset[:data], threshold)

        {
          success: true,
          dataset_name: dataset_name,
          correlations: correlations,
          threshold: threshold,
          analyzed_at: Time.now.iso8601
        }
      rescue StandardError => e
        { success: false, error: "Correlation analysis failed: #{e.message}" }
      end
    end

    # Trend detection
    @server.register_tool(
      name: "detect_trends",
      description: "Identify trends in time series data",
      input_schema: {
        type: "object",
        properties: {
          dataset_name: {
            type: "string",
            description: "Name of the dataset to analyze"
          },
          time_column: {
            type: "string",
            description: "Column containing time/date values"
          },
          value_column: {
            type: "string",
            description: "Column containing values to analyze"
          },
          window_size: {
            type: "integer",
            minimum: 3,
            maximum: 100,
            default: 7,
            description: "Moving average window size"
          }
        },
        required: %w[dataset_name time_column value_column],
        additionalProperties: false
      }
    ) do |arguments, _session_context|
      dataset_name = arguments["dataset_name"]
      time_column = arguments["time_column"]
      value_column = arguments["value_column"]
      window_size = arguments["window_size"] || 7

      dataset = @datasets[dataset_name]
      return { success: false, error: "Dataset not found: #{dataset_name}" } unless dataset

      begin
        trends = detect_time_series_trends(dataset[:data], time_column, value_column, window_size)

        {
          success: true,
          dataset_name: dataset_name,
          trends: trends,
          parameters: {
            time_column: time_column,
            value_column: value_column,
            window_size: window_size
          },
          analyzed_at: Time.now.iso8601
        }
      rescue StandardError => e
        { success: false, error: "Trend analysis failed: #{e.message}" }
      end
    end

    # Data quality assessment
    @server.register_tool(
      name: "assess_quality",
      description: "Assess data quality and identify issues",
      input_schema: {
        type: "object",
        properties: {
          dataset_name: {
            type: "string",
            description: "Name of the dataset to assess"
          }
        },
        required: ["dataset_name"],
        additionalProperties: false
      }
    ) do |arguments, _session_context|
      dataset_name = arguments["dataset_name"]

      dataset = @datasets[dataset_name]
      return { success: false, error: "Dataset not found: #{dataset_name}" } unless dataset

      begin
        quality_report = assess_data_quality(dataset[:data])

        {
          success: true,
          dataset_name: dataset_name,
          quality_report: quality_report,
          assessed_at: Time.now.iso8601
        }
      rescue StandardError => e
        { success: false, error: "Quality assessment failed: #{e.message}" }
      end
    end
  end

  def register_export_tools
    # Export analysis results
    @server.register_tool(
      name: "export_results",
      description: "Export analysis results to various formats",
      input_schema: {
        type: "object",
        properties: {
          results: {
            type: "object",
            description: "Analysis results to export"
          },
          format: {
            type: "string",
            enum: %w[json csv excel pdf html],
            description: "Export format"
          },
          filename: {
            type: "string",
            description: "Output filename"
          }
        },
        required: %w[results format filename],
        additionalProperties: false
      }
    ) do |arguments, _session_context|
      results = arguments["results"]
      format = arguments["format"]
      filename = arguments["filename"]

      begin
        output_path = export_analysis_results(results, format, filename)

        {
          success: true,
          format: format,
          output_path: output_path,
          file_size: File.size(output_path),
          exported_at: Time.now.iso8601
        }
      rescue StandardError => e
        { success: false, error: "Export failed: #{e.message}" }
      end
    end

    # Generate comprehensive report
    @server.register_tool(
      name: "generate_report",
      description: "Generate comprehensive analysis report",
      input_schema: {
        type: "object",
        properties: {
          dataset_name: {
            type: "string",
            description: "Name of the dataset to report on"
          },
          format: {
            type: "string",
            enum: %w[markdown html pdf],
            default: "markdown",
            description: "Report format"
          },
          include_charts: {
            type: "boolean",
            default: false,
            description: "Include data visualizations"
          }
        },
        required: ["dataset_name"],
        additionalProperties: false
      }
    ) do |arguments, _session_context|
      dataset_name = arguments["dataset_name"]
      format = arguments["format"] || "markdown"
      include_charts = arguments["include_charts"] || false

      dataset = @datasets[dataset_name]
      return { success: false, error: "Dataset not found: #{dataset_name}" } unless dataset

      begin
        report = generate_comprehensive_report(dataset, format, include_charts)

        {
          success: true,
          dataset_name: dataset_name,
          report: report,
          format: format,
          generated_at: Time.now.iso8601
        }
      rescue StandardError => e
        { success: false, error: "Report generation failed: #{e.message}" }
      end
    end
  end

  def register_visualization_tools
    # Create simple charts
    @server.register_tool(
      name: "create_chart",
      description: "Create data visualization charts",
      input_schema: {
        type: "object",
        properties: {
          dataset_name: {
            type: "string",
            description: "Name of the dataset to visualize"
          },
          chart_type: {
            type: "string",
            enum: %w[bar line pie scatter histogram],
            description: "Type of chart to create"
          },
          x_column: {
            type: "string",
            description: "Column for X-axis"
          },
          y_column: {
            type: "string",
            description: "Column for Y-axis"
          },
          title: {
            type: "string",
            description: "Chart title"
          }
        },
        required: %w[dataset_name chart_type],
        additionalProperties: false
      }
    ) do |arguments, _session_context|
      dataset_name = arguments["dataset_name"]
      chart_type = arguments["chart_type"]
      x_column = arguments["x_column"]
      y_column = arguments["y_column"]
      title = arguments["title"]

      dataset = @datasets[dataset_name]
      return { success: false, error: "Dataset not found: #{dataset_name}" } unless dataset

      begin
        chart_data = create_chart_data(dataset[:data], chart_type, x_column, y_column, title)

        {
          success: true,
          chart_type: chart_type,
          chart_data: chart_data,
          created_at: Time.now.iso8601
        }
      rescue StandardError => e
        { success: false, error: "Chart creation failed: #{e.message}" }
      end
    end
  end

  # Helper methods for data loading

  def load_csv_data(source, options)
    csv_options = { headers: true }.merge(options.transform_keys(&:to_sym))

    if source.start_with?("http")
      require "net/http"
      uri = URI(source)
      response = Net::HTTP.get_response(uri)
      CSV.parse(response.body, **csv_options).map(&:to_h)
    else
      CSV.read(source, **csv_options).map(&:to_h)
    end
  end

  def load_json_data(source, headers)
    if source.start_with?("http")
      require "net/http"
      uri = URI(source)
      request = Net::HTTP::Get.new(uri)
      headers.each { |key, value| request[key] = value }

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.request(request)
      end

      JSON.parse(response.body)
    else
      JSON.parse(File.read(source))
    end
  end

  def load_yaml_data(source)
    YAML.safe_load_file(source)
  end

  def load_api_data(source, headers, _options)
    # Implement API-specific loading logic
    # This would vary based on the API requirements
    load_json_data(source, headers)
  end

  def validate_dataset(data)
    return [] if data.empty?

    # Ensure all rows have consistent structure
    expected_keys = data.first.keys
    data.select { |row| row.keys == expected_keys }
  end

  def generate_metadata(data)
    return {} if data.empty?

    sample_row = data.first
    columns = sample_row.keys

    {
      total_rows: data.size,
      columns: columns.map do |col|
        values = data.map { |row| row[col] }.compact
        {
          name: col,
          type: detect_column_type(values),
          non_null_count: values.size,
          null_count: data.size - values.size,
          unique_count: values.uniq.size
        }
      end
    }
  end

  def detect_column_type(values)
    return "unknown" if values.empty?

    sample = values.first(100)

    if sample.all? { |v| v.is_a?(Numeric) || (v.is_a?(String) && v.match?(/^\d+(\.\d+)?$/)) }
      "numeric"
    elsif sample.all? { |v| v.is_a?(String) && v.match?(/^\d{4}-\d{2}-\d{2}/) }
      "date"
    else
      "text"
    end
  end

  # Analysis methods

  def perform_statistical_analysis(data, specific_columns)
    numeric_columns = get_numeric_columns(data, specific_columns)

    numeric_columns.map do |column|
      values = data.map { |row| to_numeric(row[column]) }.compact

      {
        column: column,
        count: values.size,
        mean: values.sum.to_f / values.size,
        median: calculate_median(values),
        min: values.min,
        max: values.max,
        std_dev: calculate_std_dev(values),
        quartiles: calculate_quartiles(values)
      }
    end
  end

  def find_correlations(data, threshold)
    numeric_columns = get_numeric_columns(data)
    correlations = []

    numeric_columns.combination(2) do |col1, col2|
      values1 = data.map { |row| to_numeric(row[col1]) }.compact
      values2 = data.map { |row| to_numeric(row[col2]) }.compact

      correlation = calculate_correlation(values1, values2)

      if correlation.abs >= threshold
        correlations << {
          column1: col1,
          column2: col2,
          correlation: correlation,
          strength: correlation_strength(correlation.abs)
        }
      end
    end

    correlations.sort_by { |c| -c[:correlation].abs }
  end

  def detect_time_series_trends(data, time_column, value_column, window_size)
    # Sort by time column
    sorted_data = data.sort_by { |row| parse_time(row[time_column]) }
    values = sorted_data.map { |row| to_numeric(row[value_column]) }.compact

    # Calculate moving average
    moving_avg = calculate_moving_average(values, window_size)

    # Detect trend direction
    trend_direction = if moving_avg.last > moving_avg.first
                        "increasing"
                      elsif moving_avg.last < moving_avg.first
                        "decreasing"
                      else
                        "stable"
                      end

    {
      trend_direction: trend_direction,
      moving_average: moving_avg,
      trend_strength: calculate_trend_strength(moving_avg),
      data_points: values.size
    }
  end

  def assess_data_quality(data)
    return { issues: ["Empty dataset"] } if data.empty?

    columns = data.first.keys
    issues = []

    columns.each do |column|
      values = data.map { |row| row[column] }
      null_count = values.count(&:nil?)
      null_percentage = (null_count.to_f / data.size) * 100

      issues << "High null percentage in #{column}: #{null_percentage.round(1)}%" if null_percentage > 10

      # Check for duplicate rows
      if column == columns.first
        duplicate_count = data.size - data.uniq.size
        issues << "#{duplicate_count} duplicate rows found" if duplicate_count.positive?
      end
    end

    {
      total_rows: data.size,
      total_columns: columns.size,
      issues: issues,
      quality_score: calculate_quality_score(data, issues)
    }
  end

  # Utility methods

  def get_numeric_columns(data, specific_columns = nil)
    return [] if data.empty?

    columns = specific_columns || data.first.keys
    columns.select do |column|
      sample_values = data.first(10).map { |row| row[column] }.compact
      sample_values.any? { |v| numeric?(v) }
    end
  end

  def numeric?(value)
    return true if value.is_a?(Numeric)
    return false unless value.is_a?(String)

    value.match?(/^\d+(\.\d+)?$/)
  end

  def to_numeric(value)
    return value if value.is_a?(Numeric)
    return nil unless value.is_a?(String)

    Float(value, exception: false)
  end

  def parse_time(value)
    Time.parse(value.to_s)
  rescue StandardError
    Time.at(0)
  end

  def calculate_median(values)
    sorted = values.sort
    mid = sorted.size / 2

    if sorted.size.even?
      (sorted[mid - 1] + sorted[mid]) / 2.0
    else
      sorted[mid]
    end
  end

  def calculate_std_dev(values)
    mean = values.sum.to_f / values.size
    variance = values.sum { |v| (v - mean)**2 } / values.size
    Math.sqrt(variance)
  end

  def calculate_quartiles(values)
    sorted = values.sort
    {
      q1: calculate_percentile(sorted, 25),
      q2: calculate_percentile(sorted, 50),
      q3: calculate_percentile(sorted, 75)
    }
  end

  def calculate_percentile(sorted_values, percentile)
    index = (percentile / 100.0) * (sorted_values.size - 1)
    lower = sorted_values[index.floor]
    upper = sorted_values[index.ceil]

    lower + ((upper - lower) * (index - index.floor))
  end

  def calculate_correlation(values1, values2)
    return 0 if values1.size != values2.size || values1.size < 2

    mean1 = values1.sum.to_f / values1.size
    mean2 = values2.sum.to_f / values2.size

    numerator = values1.zip(values2).sum { |x, y| (x - mean1) * (y - mean2) }
    denominator = Math.sqrt(
      values1.sum { |x| (x - mean1)**2 } *
      values2.sum { |y| (y - mean2)**2 }
    )

    denominator.zero? ? 0 : numerator / denominator
  end

  def correlation_strength(correlation)
    case correlation
    when 0...0.3 then "weak"
    when 0.3...0.7 then "moderate"
    else "strong"
    end
  end

  def calculate_moving_average(values, window_size)
    (0...(values.size - window_size + 1)).map do |i|
      values[i, window_size].sum.to_f / window_size
    end
  end

  def calculate_trend_strength(moving_avg)
    return 0 if moving_avg.size < 2

    changes = moving_avg.each_cons(2).map { |a, b| b - a }
    consistent_direction = changes.count(&:positive?) - changes.count(&:negative?)
    (consistent_direction.abs.to_f / changes.size).round(2)
  end

  def calculate_quality_score(_data, issues)
    base_score = 100
    penalty_per_issue = 10

    [base_score - (issues.size * penalty_per_issue), 0].max
  end

  # Export and reporting methods

  def export_analysis_results(results, format, filename)
    output_dir = File.join("tmp", "data_analysis", "exports")
    FileUtils.mkdir_p(output_dir)
    output_path = File.join(output_dir, filename)

    case format
    when "json"
      File.write(output_path, JSON.pretty_generate(results))
    when "csv"
      # Convert results to CSV format
      CSV.open(output_path, "w") do |csv|
        if results.is_a?(Array) && results.first.is_a?(Hash)
          csv << results.first.keys
          results.each { |row| csv << row.values }
        end
      end
    when "yaml"
      File.write(output_path, YAML.dump(results))
    else
      File.write(output_path, results.to_s)
    end

    output_path
  end

  def generate_comprehensive_report(dataset, format, include_charts)
    data = dataset[:data]
    metadata = dataset[:metadata]

    report_content = case format
                     when "markdown"
                       generate_markdown_report(data, metadata, include_charts)
                     when "html"
                       generate_html_report(data, metadata, include_charts)
                     else
                       generate_text_report(data, metadata)
                     end

    # Save report to file
    output_dir = File.join("tmp", "data_analysis", "reports")
    FileUtils.mkdir_p(output_dir)
    timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
    filename = "data_analysis_report_#{timestamp}.#{format}"
    output_path = File.join(output_dir, filename)

    File.write(output_path, report_content)

    {
      content: report_content,
      file_path: output_path,
      format: format
    }
  end

  def generate_markdown_report(data, metadata, include_charts)
    md = []
    md << "# Data Analysis Report"
    md << ""
    md << "**Generated:** #{Time.now.strftime("%Y-%m-%d %H:%M:%S")}"
    md << "**Dataset Size:** #{data.size} rows, #{metadata[:columns].size} columns"
    md << ""

    md << "## Dataset Overview"
    md << ""
    md << "| Column | Type | Non-Null | Unique Values |"
    md << "|--------|------|----------|---------------|"

    metadata[:columns].each do |col|
      md << "| #{col[:name]} | #{col[:type]} | #{col[:non_null_count]} | #{col[:unique_count]} |"
    end

    md << ""
    md << "## Sample Data"
    md << ""
    md << "```json"
    md << JSON.pretty_generate(data.first(3))
    md << "```"

    if include_charts
      md << ""
      md << "## Visualizations"
      md << ""
      md << "*Charts would be generated here in a full implementation*"
    end

    md.join("\n")
  end

  def generate_html_report(data, metadata, _include_charts)
    # Simple HTML report generation
    html = ["<html><head><title>Data Analysis Report</title></head><body>"]
    html << "<h1>Data Analysis Report</h1>"
    html << "<p><strong>Generated:</strong> #{Time.now.strftime("%Y-%m-%d %H:%M:%S")}</p>"
    html << "<p><strong>Dataset Size:</strong> #{data.size} rows, #{metadata[:columns].size} columns</p>"

    html << "<h2>Dataset Overview</h2>"
    html << "<table border='1'>"
    html << "<tr><th>Column</th><th>Type</th><th>Non-Null</th><th>Unique Values</th></tr>"

    metadata[:columns].each do |col|
      html << "<tr><td>#{col[:name]}</td><td>#{col[:type]}</td><td>#{col[:non_null_count]}</td><td>#{col[:unique_count]}</td></tr>"
    end

    html << "</table>"
    html << "</body></html>"
    html.join("\n")
  end

  def generate_text_report(data, metadata)
    lines = []
    lines << "DATA ANALYSIS REPORT"
    lines << ("=" * 50)
    lines << "Generated: #{Time.now.strftime("%Y-%m-%d %H:%M:%S")}"
    lines << "Dataset Size: #{data.size} rows, #{metadata[:columns].size} columns"
    lines << ""
    lines << "COLUMNS:"
    lines << ("-" * 20)

    metadata[:columns].each do |col|
      lines << "#{col[:name]}: #{col[:type]} (#{col[:non_null_count]} non-null, #{col[:unique_count]} unique)"
    end

    lines.join("\n")
  end

  def create_chart_data(data, chart_type, x_column, y_column, title)
    # Simple chart data generation
    # In a real implementation, this would integrate with charting libraries

    case chart_type
    when "bar", "line"
      {
        type: chart_type,
        title: title || "#{y_column} by #{x_column}",
        x_axis: data.map { |row| row[x_column] },
        y_axis: data.map { |row| to_numeric(row[y_column]) }.compact,
        x_label: x_column,
        y_label: y_column
      }
    when "pie"
      value_counts = data.group_by { |row| row[x_column] }.transform_values(&:count)
      {
        type: chart_type,
        title: title || "Distribution of #{x_column}",
        labels: value_counts.keys,
        values: value_counts.values
      }
    when "scatter"
      {
        type: chart_type,
        title: title || "#{y_column} vs #{x_column}",
        points: data.map do |row|
          {
            x: to_numeric(row[x_column]),
            y: to_numeric(row[y_column])
          }
        end.compact,
        x_label: x_column,
        y_label: y_column
      }
    when "histogram"
      values = data.map { |row| to_numeric(row[x_column || y_column]) }.compact
      bins = create_histogram_bins(values, 10)
      {
        type: chart_type,
        title: title || "Distribution of #{x_column || y_column}",
        bins: bins
      }
    end
  end

  def create_histogram_bins(values, num_bins)
    min_val = values.min
    max_val = values.max
    bin_width = (max_val - min_val).to_f / num_bins

    bins = Array.new(num_bins, 0)

    values.each do |value|
      bin_index = [(value - min_val) / bin_width, num_bins - 1].min.to_i
      bins[bin_index] += 1
    end

    bins.map.with_index do |count, index|
      {
        range: "#{(min_val + (index * bin_width)).round(2)}-#{(min_val + ((index + 1) * bin_width)).round(2)}",
        count: count
      }
    end
  end
end

# Run the server
if __FILE__ == $PROGRAM_NAME
  server = DataAnalysisServer.new
  server.run
end
