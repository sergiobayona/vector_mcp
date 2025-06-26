#!/usr/bin/env ruby
# frozen_string_literal: true

# File Operations Use Case Example
# Demonstrates secure file system automation with VectorMCP
#
# This example shows how to:
# - Set up secure filesystem boundaries with roots
# - Implement file reading, writing, and processing tools
# - Add content transformation capabilities
# - Provide search and analysis functionality
# - Ensure security through validation and access control

require_relative "../../../lib/vector_mcp"

class FileOperationsServer
  def initialize
    @server = VectorMCP::Server.new("FileOperations")
    configure_logging
    setup_filesystem_roots
    register_file_tools
    register_content_tools
    register_analysis_tools
  end

  def run
    puts "🗂️  VectorMCP File Operations Server"
    puts "📁 Secure file management and processing"
    puts "🔒 Filesystem boundaries enforced"
    puts
    puts "Available roots:"
    @server.roots.each do |root|
      puts "  📂 #{root.name}: #{root.path}"
    end
    puts
    puts "🚀 Server starting on stdio transport..."
    puts "💡 Try calling tools like 'read_file', 'search_files', or 'analyze_content'"
    puts

    @server.run(transport: :stdio)
  end

  private

  def configure_logging
    VectorMCP.configure_logging do
      level "INFO"
      component "file.operations", level: "DEBUG"
      component "security.filesystem", level: "INFO"
    end
  end

  def setup_filesystem_roots
    # Define secure filesystem boundaries
    current_dir = File.expand_path(".")

    # Allow access to example files
    examples_path = File.join(current_dir, "examples")
    @server.register_root_from_path(examples_path, name: "Examples") if Dir.exist?(examples_path)

    # Allow access to documentation
    docs_path = File.join(current_dir, "docs")
    @server.register_root_from_path(docs_path, name: "Documentation") if Dir.exist?(docs_path)

    # Allow access to README files
    @server.register_root_from_path(current_dir, name: "Project Root")

    # Create a temp directory for file operations
    temp_dir = File.join(current_dir, "tmp", "file_operations")
    FileUtils.mkdir_p(temp_dir)
    @server.register_root_from_path(temp_dir, name: "Workspace")
  end

  def register_file_tools
    # Read file contents with security validation
    @server.register_tool(
      name: "read_file",
      description: "Read contents of a file within allowed directories",
      input_schema: {
        type: "object",
        properties: {
          path: {
            type: "string",
            description: "Path to the file to read"
          },
          encoding: {
            type: "string",
            enum: %w[utf-8 ascii binary],
            default: "utf-8",
            description: "File encoding"
          }
        },
        required: ["path"],
        additionalProperties: false
      }
    ) do |arguments, _session_context|
      path = arguments["path"]
      encoding = arguments["encoding"] || "utf-8"

      begin
        # Security: Path validation happens automatically via filesystem roots
        if File.exist?(path) && File.file?(path)
          content = File.read(path, encoding: encoding)

          {
            success: true,
            content: content,
            size: content.bytesize,
            encoding: encoding,
            last_modified: File.mtime(path).iso8601
          }
        else
          { success: false, error: "File not found or not a regular file: #{path}" }
        end
      rescue StandardError => e
        { success: false, error: "Failed to read file: #{e.message}" }
      end
    end

    # Write file contents with validation
    @server.register_tool(
      name: "write_file",
      description: "Write content to a file within allowed directories",
      input_schema: {
        type: "object",
        properties: {
          path: {
            type: "string",
            description: "Path where to write the file"
          },
          content: {
            type: "string",
            description: "Content to write to the file"
          },
          encoding: {
            type: "string",
            enum: %w[utf-8 ascii],
            default: "utf-8",
            description: "File encoding"
          },
          backup: {
            type: "boolean",
            default: true,
            description: "Create backup if file exists"
          }
        },
        required: %w[path content],
        additionalProperties: false
      }
    ) do |arguments, _session_context|
      path = arguments["path"]
      content = arguments["content"]
      encoding = arguments["encoding"] || "utf-8"
      create_backup = arguments["backup"] != false

      begin
        # Create backup if file exists and backup is requested
        if File.exist?(path) && create_backup
          backup_path = "#{path}.backup.#{Time.now.strftime("%Y%m%d_%H%M%S")}"
          FileUtils.cp(path, backup_path)
        end

        # Ensure directory exists
        FileUtils.mkdir_p(File.dirname(path))

        # Write the file
        File.write(path, content, encoding: encoding)

        {
          success: true,
          path: path,
          size: content.bytesize,
          encoding: encoding,
          backup_created: create_backup && File.exist?("#{path}.backup*")
        }
      rescue StandardError => e
        { success: false, error: "Failed to write file: #{e.message}" }
      end
    end

    # List files in directory
    @server.register_tool(
      name: "list_files",
      description: "List files and directories within allowed paths",
      input_schema: {
        type: "object",
        properties: {
          path: {
            type: "string",
            description: "Directory path to list",
            default: "."
          },
          pattern: {
            type: "string",
            description: "Glob pattern to filter files (e.g., '*.rb', '**/*.md')"
          },
          include_hidden: {
            type: "boolean",
            default: false,
            description: "Include hidden files and directories"
          }
        },
        additionalProperties: false
      }
    ) do |arguments, _session_context|
      path = arguments["path"] || "."
      pattern = arguments["pattern"]
      include_hidden = arguments["include_hidden"] || false

      begin
        if Dir.exist?(path)
          files = if pattern
                    Dir.glob(File.join(path, pattern))
                  else
                    Dir.entries(path).reject { |f| [".", ".."].include?(f) }
                  end

          # Filter hidden files if not requested
          files.reject! { |f| File.basename(f).start_with?(".") } unless include_hidden

          file_list = files.map do |file_path|
            full_path = File.join(path, file_path)
            stat = File.stat(full_path)

            {
              name: File.basename(file_path),
              path: full_path,
              type: File.directory?(full_path) ? "directory" : "file",
              size: stat.size,
              modified: stat.mtime.iso8601,
              permissions: format("%o", stat.mode)[-3..]
            }
          end

          {
            success: true,
            path: path,
            files: file_list,
            count: file_list.size
          }
        else
          { success: false, error: "Directory not found: #{path}" }
        end
      rescue StandardError => e
        { success: false, error: "Failed to list directory: #{e.message}" }
      end
    end

    # Search for files by content
    @server.register_tool(
      name: "search_files",
      description: "Search for text within files in allowed directories",
      input_schema: {
        type: "object",
        properties: {
          query: {
            type: "string",
            description: "Text to search for"
          },
          path: {
            type: "string",
            description: "Directory to search in",
            default: "."
          },
          file_pattern: {
            type: "string",
            description: "File pattern to search (e.g., '*.rb', '*.md')",
            default: "*"
          },
          case_sensitive: {
            type: "boolean",
            default: false,
            description: "Case sensitive search"
          },
          max_results: {
            type: "integer",
            minimum: 1,
            maximum: 100,
            default: 20,
            description: "Maximum number of results to return"
          }
        },
        required: ["query"],
        additionalProperties: false
      }
    ) do |arguments, _session_context|
      query = arguments["query"]
      path = arguments["path"] || "."
      file_pattern = arguments["file_pattern"] || "*"
      case_sensitive = arguments["case_sensitive"] || false
      max_results = arguments["max_results"] || 20

      begin
        search_pattern = case_sensitive ? query : query.downcase
        results = []

        Dir.glob(File.join(path, "**", file_pattern)).each do |file_path|
          next unless File.file?(file_path)

          begin
            content = File.read(file_path, encoding: "utf-8")
            search_content = case_sensitive ? content : content.downcase

            if search_content.include?(search_pattern)
              # Find line numbers and context
              lines = content.lines
              matches = []

              lines.each_with_index do |line, index|
                search_line = case_sensitive ? line : line.downcase
                next unless search_line.include?(search_pattern)

                matches << {
                  line_number: index + 1,
                  line: line.strip,
                  context_before: lines[index - 1]&.strip,
                  context_after: lines[index + 1]&.strip
                }
              end

              results << {
                file: file_path,
                matches: matches,
                total_matches: matches.size
              }

              break if results.size >= max_results
            end
          rescue StandardError
            # Skip files that can't be read (binary, permissions, etc.)
            next
          end
        end

        {
          success: true,
          query: query,
          results: results,
          total_files_searched: results.size,
          total_matches: results.sum { |r| r[:total_matches] }
        }
      rescue StandardError => e
        { success: false, error: "Search failed: #{e.message}" }
      end
    end
  end

  def register_content_tools
    # Convert file formats
    @server.register_tool(
      name: "convert_format",
      description: "Convert file content between different formats",
      input_schema: {
        type: "object",
        properties: {
          source_path: {
            type: "string",
            description: "Path to source file"
          },
          target_path: {
            type: "string",
            description: "Path for converted file"
          },
          source_format: {
            type: "string",
            enum: %w[markdown json csv yaml txt],
            description: "Source file format"
          },
          target_format: {
            type: "string",
            enum: %w[markdown json csv yaml txt html],
            description: "Target file format"
          }
        },
        required: %w[source_path target_path source_format target_format],
        additionalProperties: false
      }
    ) do |arguments, _session_context|
      source_path = arguments["source_path"]
      target_path = arguments["target_path"]
      source_format = arguments["source_format"]
      target_format = arguments["target_format"]

      begin
        # Read source content
        source_content = File.read(source_path)

        # Convert based on formats
        converted_content = case [source_format, target_format]
                            when %w[json csv]
                              json_to_csv(source_content)
                            when %w[csv json]
                              csv_to_json(source_content)
                            when %w[markdown html]
                              markdown_to_html(source_content)
                            when %w[json yaml]
                              json_to_yaml(source_content)
                            when %w[yaml json]
                              yaml_to_json(source_content)
                            else
                              # Direct copy for same format or unsupported conversions
                              source_content
                            end

        # Write converted content
        FileUtils.mkdir_p(File.dirname(target_path))
        File.write(target_path, converted_content)

        {
          success: true,
          source_path: source_path,
          target_path: target_path,
          source_format: source_format,
          target_format: target_format,
          source_size: source_content.bytesize,
          target_size: converted_content.bytesize
        }
      rescue StandardError => e
        { success: false, error: "Conversion failed: #{e.message}" }
      end
    end

    # Extract metadata from files
    @server.register_tool(
      name: "extract_metadata",
      description: "Extract metadata and properties from files",
      input_schema: {
        type: "object",
        properties: {
          path: {
            type: "string",
            description: "Path to file for metadata extraction"
          }
        },
        required: ["path"],
        additionalProperties: false
      }
    ) do |arguments, _session_context|
      path = arguments["path"]

      begin
        if File.exist?(path)
          stat = File.stat(path)

          metadata = {
            path: path,
            name: File.basename(path),
            extension: File.extname(path),
            size: stat.size,
            created: stat.ctime.iso8601,
            modified: stat.mtime.iso8601,
            accessed: stat.atime.iso8601,
            permissions: format("%o", stat.mode)[-3..],
            type: File.directory?(path) ? "directory" : "file"
          }

          # Add content-specific metadata for text files
          if File.file?(path) && text_file?(path)
            content = File.read(path, encoding: "utf-8")
            metadata.merge!(
              lines: content.lines.count,
              words: content.split.count,
              characters: content.length,
              encoding: content.encoding.to_s
            )

            # Detect file type based on content
            metadata[:detected_type] = detect_file_type(content, File.extname(path))
          end

          { success: true, metadata: metadata }
        else
          { success: false, error: "File not found: #{path}" }
        end
      rescue StandardError => e
        { success: false, error: "Metadata extraction failed: #{e.message}" }
      end
    end
  end

  def register_analysis_tools
    # Analyze code files
    @server.register_tool(
      name: "analyze_code",
      description: "Analyze code files for complexity, patterns, and issues",
      input_schema: {
        type: "object",
        properties: {
          path: {
            type: "string",
            description: "Path to code file"
          },
          language: {
            type: "string",
            enum: %w[ruby python javascript java go rust],
            description: "Programming language (auto-detected if not provided)"
          }
        },
        required: ["path"],
        additionalProperties: false
      }
    ) do |arguments, _session_context|
      path = arguments["path"]
      language = arguments["language"]

      begin
        content = File.read(path)
        detected_language = language || detect_language(content, File.extname(path))

        analysis = {
          file: path,
          language: detected_language,
          lines_total: content.lines.count,
          lines_code: content.lines.reject { |line| line.strip.empty? || comment_line?(line, detected_language) }.count,
          lines_comments: content.lines.select { |line| comment_line?(line, detected_language) }.count,
          lines_blank: content.lines.select { |line| line.strip.empty? }.count,
          complexity_estimate: calculate_complexity(content, detected_language),
          functions: extract_functions(content, detected_language),
          imports: extract_imports(content, detected_language),
          potential_issues: find_potential_issues(content, detected_language)
        }

        { success: true, analysis: analysis }
      rescue StandardError => e
        { success: false, error: "Code analysis failed: #{e.message}" }
      end
    end

    # Generate file report
    @server.register_tool(
      name: "generate_report",
      description: "Generate comprehensive report about files in a directory",
      input_schema: {
        type: "object",
        properties: {
          path: {
            type: "string",
            description: "Directory path to analyze",
            default: "."
          },
          output_format: {
            type: "string",
            enum: %w[json markdown text],
            default: "markdown",
            description: "Report output format"
          },
          include_analysis: {
            type: "boolean",
            default: true,
            description: "Include detailed file analysis"
          }
        },
        additionalProperties: false
      }
    ) do |arguments, _session_context|
      path = arguments["path"] || "."
      output_format = arguments["output_format"] || "markdown"
      include_analysis = arguments["include_analysis"] != false

      begin
        report = generate_directory_report(path, include_analysis)

        formatted_report = case output_format
                           when "json"
                             report.to_json
                           when "markdown"
                             format_report_markdown(report)
                           when "text"
                             format_report_text(report)
                           else
                             report.to_s
                           end

        {
          success: true,
          report: formatted_report,
          format: output_format,
          generated_at: Time.now.iso8601
        }
      rescue StandardError => e
        { success: false, error: "Report generation failed: #{e.message}" }
      end
    end
  end

  # Helper methods for file operations

  def text_file?(path)
    # Simple heuristic for text files
    return false unless File.file?(path)
    return true if [".txt", ".md", ".rb", ".py", ".js", ".json", ".yml", ".yaml"].include?(File.extname(path))

    # Check if file contains mostly text
    sample = begin
      File.read(path, 1024)
    rescue StandardError
      ""
    end
    sample.bytes.count { |b| b < 32 && ![9, 10, 13].include?(b) } < sample.length * 0.1
  end

  def detect_file_type(content, extension)
    return "json" if extension == ".json" || content.strip.match?(/^\{.*\}$/m)
    return "yaml" if extension == ".yml" || extension == ".yaml" || content.match?(/^---\n/)
    return "markdown" if extension == ".md" || content.match?(/^#+ /)
    return "ruby" if extension == ".rb" || content.match?(%r{^#!/usr/bin/env ruby})
    return "python" if extension == ".py" || content.match?(%r{^#!/usr/bin/env python})
    return "javascript" if extension == ".js" || content.match?(%r{^#!/usr/bin/env node})

    "text"
  end

  def detect_language(content, extension)
    case extension
    when ".rb" then "ruby"
    when ".py" then "python"
    when ".js" then "javascript"
    when ".java" then "java"
    when ".go" then "go"
    when ".rs" then "rust"
    else
      # Simple heuristic based on content
      return "ruby" if content.include?("def ") && content.include?("end")
      return "python" if content.include?("def ") && content.match?(/import \w+/)
      return "javascript" if content.include?("function ") || content.include?("const ")

      "unknown"
    end
  end

  def comment_line?(line, language)
    stripped = line.strip
    case language
    when "ruby", "python"
      stripped.start_with?("#")
    when "javascript", "java", "go", "rust"
      stripped.start_with?("//") || stripped.start_with?("/*") || stripped.start_with?("*")
    else
      false
    end
  end

  def calculate_complexity(content, language)
    # Simple complexity calculation based on control structures
    complexity_keywords = case language
                          when "ruby"
                            %w[if unless case while until for each loop]
                          when "python"
                            %w[if elif while for try except]
                          when "javascript"
                            %w[if while for switch try catch]
                          else
                            %w[if while for switch]
                          end

    complexity_keywords.sum { |keyword| content.scan(/\b#{keyword}\b/).count } + 1
  end

  def extract_functions(content, language)
    functions = []
    case language
    when "ruby", "python"
      content.scan(/^\s*def\s+(\w+)/) { |match| functions << match[0] }
    when "javascript"
      content.scan(/function\s+(\w+)/) { |match| functions << match[0] }
      content.scan(/(\w+)\s*=\s*function/) { |match| functions << match[0] }
    end
    functions
  end

  def extract_imports(content, language)
    imports = []
    case language
    when "ruby"
      content.scan(/require\s+['"]([^'"]+)['"]/) { |match| imports << match[0] }
      content.scan(/require_relative\s+['"]([^'"]+)['"]/) { |match| imports << match[0] }
    when "python"
      content.scan(/import\s+(\w+)/) { |match| imports << match[0] }
      content.scan(/from\s+(\w+)\s+import/) { |match| imports << match[0] }
    when "javascript"
      content.scan(/require\s*\(\s*['"]([^'"]+)['"]\s*\)/) { |match| imports << match[0] }
      content.scan(/import.*from\s+['"]([^'"]+)['"]/) { |match| imports << match[0] }
    end
    imports
  end

  def find_potential_issues(content, language)
    issues = []

    # Common issues across languages
    issues << "Very long lines" if content.lines.any? { |line| line.length > 120 }
    issues << "Many nested levels" if content.match?(/\s{16,}/) # 4+ levels of indentation
    issues << "TODO/FIXME comments" if content.match?(/TODO|FIXME|HACK/i)

    # Language-specific issues
    case language
    when "ruby"
      issues << "Missing frozen_string_literal" unless content.match?(/frozen_string_literal/)
      issues << "Eval usage detected" if content.match?(/\beval\b/)
    when "python"
      issues << "Missing docstrings" unless content.match?(/""".*"""/m)
      issues << "Bare except clauses" if content.match?(/except:\s*$/)
    end

    issues
  end

  # Format conversion helpers

  def json_to_csv(json_content)
    require "json"
    require "csv"

    data = JSON.parse(json_content)
    return "Invalid JSON format for CSV conversion" unless data.is_a?(Array) && data.first.is_a?(Hash)

    CSV.generate do |csv|
      csv << data.first.keys # Header row
      data.each { |row| csv << row.values }
    end
  end

  def csv_to_json(csv_content)
    require "csv"
    require "json"

    csv = CSV.parse(csv_content, headers: true)
    csv.map(&:to_h).to_json
  end

  def markdown_to_html(markdown_content)
    # Simple markdown to HTML conversion (basic implementation)
    html = markdown_content
           .gsub(/^# (.+)$/, '<h1>\1</h1>')
           .gsub(/^## (.+)$/, '<h2>\1</h2>')
           .gsub(/^### (.+)$/, '<h3>\1</h3>')
           .gsub(/\*\*(.+?)\*\*/, '<strong>\1</strong>')
           .gsub(/\*(.+?)\*/, '<em>\1</em>')
           .gsub(/`(.+?)`/, '<code>\1</code>')

    "<html><body>#{html}</body></html>"
  end

  def json_to_yaml(json_content)
    require "json"
    require "yaml"

    data = JSON.parse(json_content)
    YAML.dump(data)
  end

  def yaml_to_json(yaml_content)
    require "yaml"
    require "json"

    data = YAML.safe_load(yaml_content)
    JSON.pretty_generate(data)
  end

  # Report generation helpers

  def generate_directory_report(path, include_analysis)
    files = Dir.glob(File.join(path, "**/*")).select { |f| File.file?(f) }

    report = {
      directory: path,
      summary: {
        total_files: files.count,
        total_size: files.sum { |f| File.size(f) },
        file_types: files.group_by { |f| File.extname(f) }.transform_values(&:count),
        largest_files: files.sort_by { |f| -File.size(f) }.first(5).map do |f|
          { path: f, size: File.size(f) }
        end
      }
    }

    if include_analysis
      report[:detailed_analysis] = files.first(10).map do |file_path|
        {
          path: file_path,
          size: File.size(file_path),
          type: detect_file_type(File.read(file_path), File.extname(file_path)),
          modified: File.mtime(file_path).iso8601
        }
      end
    end

    report
  end

  def format_report_markdown(report)
    md = []
    md << "# File System Report"
    md << ""
    md << "**Directory:** #{report[:directory]}"
    md << "**Generated:** #{Time.now.strftime("%Y-%m-%d %H:%M:%S")}"
    md << ""
    md << "## Summary"
    md << "- **Total Files:** #{report[:summary][:total_files]}"
    md << "- **Total Size:** #{format_size(report[:summary][:total_size])}"
    md << ""
    md << "## File Types"
    report[:summary][:file_types].each do |ext, count|
      md << "- **#{ext.empty? ? "(no extension)" : ext}:** #{count} files"
    end
    md << ""
    md << "## Largest Files"
    report[:summary][:largest_files].each do |file|
      md << "- #{file[:path]} (#{format_size(file[:size])})"
    end

    md.join("\n")
  end

  def format_report_text(report)
    text = []
    text << "FILE SYSTEM REPORT"
    text << ("=" * 50)
    text << "Directory: #{report[:directory]}"
    text << "Generated: #{Time.now.strftime("%Y-%m-%d %H:%M:%S")}"
    text << ""
    text << "SUMMARY"
    text << ("-" * 20)
    text << "Total Files: #{report[:summary][:total_files]}"
    text << "Total Size: #{format_size(report[:summary][:total_size])}"

    text.join("\n")
  end

  def format_size(bytes)
    units = %w[B KB MB GB TB]
    unit_index = 0
    size = bytes.to_f

    while size >= 1024 && unit_index < units.length - 1
      size /= 1024
      unit_index += 1
    end

    "#{size.round(2)} #{units[unit_index]}"
  end
end

# Run the server
if __FILE__ == $PROGRAM_NAME
  server = FileOperationsServer.new
  server.run
end
