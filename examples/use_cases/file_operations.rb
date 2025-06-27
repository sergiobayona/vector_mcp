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
    @logger = VectorMCP.logger_for("file_operations")
  end

  def setup_filesystem_roots
    # Register current directory as workspace
    current_dir = Dir.pwd
    @server.register_root_from_path(current_dir, name: "Workspace")

    # Create and register a safe operations directory
    @operations_dir = File.join(__dir__, "file_workspace")
    FileUtils.mkdir_p(@operations_dir)
    @server.register_root_from_path(@operations_dir, name: "Operations")

    @logger.info("Filesystem roots configured", roots: @server.roots.keys)
  end

  def register_file_tools
    # Tool to read file contents
    @server.register_tool(
      name: "read_file",
      description: "Read contents of a file within registered roots",
      input_schema: {
        type: "object",
        properties: {
          file_path: { type: "string", description: "Path to the file to read" },
          encoding: { type: "string", description: "File encoding (default: UTF-8)", default: "UTF-8" }
        },
        required: ["file_path"]
      }
    ) do |args, _session|
      file_path = args["file_path"]
      encoding = args.fetch("encoding", "UTF-8")

      @logger.info("Reading file", path: file_path, encoding: encoding)

      begin
        # Security check: ensure file is within a registered root
        absolute_path = File.expand_path(file_path)
        within_root = @server.roots.any? do |_uri, root|
          absolute_path.start_with?(File.expand_path(root.path))
        end

        return { status: "error", error: "File path is outside registered roots" } unless within_root

        return { status: "error", error: "File not found" } unless File.exist?(absolute_path)

        return { status: "error", error: "File not readable" } unless File.readable?(absolute_path)

        content = File.read(absolute_path, encoding: encoding)
        file_info = File.stat(absolute_path)

        {
          status: "success",
          file_path: file_path,
          content: content,
          size_bytes: file_info.size,
          modified_at: file_info.mtime,
          encoding: encoding
        }
      rescue StandardError => e
        @logger.error("Failed to read file", path: file_path, error: e.message)
        { status: "error", error: e.message }
      end
    end

    # Tool to write file contents
    @server.register_tool(
      name: "write_file",
      description: "Write content to a file within registered roots",
      input_schema: {
        type: "object",
        properties: {
          file_path: { type: "string", description: "Path where to write the file" },
          content: { type: "string", description: "Content to write" },
          encoding: { type: "string", description: "File encoding (default: UTF-8)", default: "UTF-8" },
          append: { type: "boolean", description: "Append to file instead of overwriting", default: false }
        },
        required: %w[file_path content]
      }
    ) do |args, _session|
      file_path = args["file_path"]
      content = args["content"]
      encoding = args.fetch("encoding", "UTF-8")
      append = args.fetch("append", false)

      @logger.info("Writing file", path: file_path, append: append, size: content.bytesize)

      begin
        absolute_path = File.expand_path(file_path)
        within_root = @server.roots.any? do |_uri, root|
          absolute_path.start_with?(File.expand_path(root.path))
        end

        return { status: "error", error: "File path is outside registered roots" } unless within_root

        # Ensure directory exists
        dir = File.dirname(absolute_path)
        FileUtils.mkdir_p(dir)

        mode = append ? "a" : "w"
        File.write(absolute_path, content, mode: mode, encoding: encoding)

        file_info = File.stat(absolute_path)

        {
          status: "success",
          file_path: file_path,
          bytes_written: content.bytesize,
          size_bytes: file_info.size,
          modified_at: file_info.mtime,
          append_mode: append
        }
      rescue StandardError => e
        @logger.error("Failed to write file", path: file_path, error: e.message)
        { status: "error", error: e.message }
      end
    end

    # Tool to list directory contents
    @server.register_tool(
      name: "list_directory",
      description: "List contents of a directory within registered roots",
      input_schema: {
        type: "object",
        properties: {
          directory_path: { type: "string", description: "Path to the directory" },
          include_hidden: { type: "boolean", description: "Include hidden files", default: false },
          file_details: { type: "boolean", description: "Include file size and modification time", default: false }
        },
        required: ["directory_path"]
      }
    ) do |args, _session|
      directory_path = args["directory_path"]
      include_hidden = args.fetch("include_hidden", false)
      file_details = args.fetch("file_details", false)

      begin
        absolute_path = File.expand_path(directory_path)
        within_root = @server.roots.any? do |_uri, root|
          absolute_path.start_with?(File.expand_path(root.path))
        end

        return { status: "error", error: "Directory path is outside registered roots" } unless within_root

        return { status: "error", error: "Directory not found" } unless Dir.exist?(absolute_path)

        entries = Dir.entries(absolute_path)
        entries = entries.reject { |e| e.start_with?(".") } unless include_hidden

        if file_details
          detailed_entries = entries.map do |entry|
            entry_path = File.join(absolute_path, entry)
            if File.exist?(entry_path)
              stat = File.stat(entry_path)
              {
                name: entry,
                type: File.directory?(entry_path) ? "directory" : "file",
                size_bytes: stat.size,
                modified_at: stat.mtime,
                readable: File.readable?(entry_path),
                writable: File.writable?(entry_path)
              }
            else
              { name: entry, type: "unknown" }
            end
          end

          {
            status: "success",
            directory: directory_path,
            entries: detailed_entries,
            total_count: detailed_entries.size
          }
        else
          {
            status: "success",
            directory: directory_path,
            entries: entries.sort,
            total_count: entries.size
          }
        end
      rescue StandardError => e
        { status: "error", error: e.message }
      end
    end
  end

  def register_content_tools
    # Tool to search files for content
    @server.register_tool(
      name: "search_files",
      description: "Search for text patterns in files within registered roots",
      input_schema: {
        type: "object",
        properties: {
          pattern: { type: "string", description: "Text pattern to search for" },
          directory: { type: "string", description: "Directory to search in (default: all roots)" },
          file_extension: { type: "string", description: "Filter by file extension (e.g., '.rb', '.txt')" },
          case_sensitive: { type: "boolean", description: "Case sensitive search", default: false },
          max_results: { type: "integer", description: "Maximum number of results", default: 50 }
        },
        required: ["pattern"]
      }
    ) do |args, _session|
      pattern = args["pattern"]
      directory = args["directory"]
      file_extension = args["file_extension"]
      case_sensitive = args.fetch("case_sensitive", false)
      max_results = args.fetch("max_results", 50)

      search_dirs = if directory
                      [File.expand_path(directory)]
                    else
                      @server.roots.values.map { |root| File.expand_path(root.path) }
                    end

      results = []
      regex_flags = case_sensitive ? 0 : Regexp::IGNORECASE
      search_regex = Regexp.new(Regexp.escape(pattern), regex_flags)

      search_dirs.each do |search_dir|
        break if results.size >= max_results

        Dir.glob("#{search_dir}/**/*").each do |file_path|
          break if results.size >= max_results

          next unless File.file?(file_path)
          next if file_extension && !file_path.end_with?(file_extension)

          begin
            File.foreach(file_path).with_index(1) do |line, line_number|
              if line.match?(search_regex)
                results << {
                  file: file_path,
                  line_number: line_number,
                  line_content: line.strip,
                  match_position: line.index(search_regex)
                }
                break if results.size >= max_results
              end
            end
          rescue StandardError
            # Skip files that can't be read
            next
          end
        end
      end

      {
        status: "success",
        pattern: pattern,
        results: results,
        total_matches: results.size,
        search_directories: search_dirs
      }
    end

    # Tool to replace text in files
    @server.register_tool(
      name: "replace_in_file",
      description: "Replace text patterns in a file",
      input_schema: {
        type: "object",
        properties: {
          file_path: { type: "string", description: "Path to the file" },
          search_pattern: { type: "string", description: "Text pattern to search for" },
          replacement: { type: "string", description: "Replacement text" },
          case_sensitive: { type: "boolean", description: "Case sensitive search", default: false },
          backup: { type: "boolean", description: "Create backup file", default: true }
        },
        required: %w[file_path search_pattern replacement]
      }
    ) do |args, _session|
      file_path = args["file_path"]
      search_pattern = args["search_pattern"]
      replacement = args["replacement"]
      case_sensitive = args.fetch("case_sensitive", false)
      backup = args.fetch("backup", true)

      begin
        absolute_path = File.expand_path(file_path)
        within_root = @server.roots.any? do |_uri, root|
          absolute_path.start_with?(File.expand_path(root.path))
        end

        return { status: "error", error: "File path is outside registered roots" } unless within_root

        return { status: "error", error: "File not found" } unless File.exist?(absolute_path)

        content = File.read(absolute_path)

        # Create backup if requested
        if backup
          backup_path = "#{absolute_path}.backup"
          File.write(backup_path, content)
        end

        regex_flags = case_sensitive ? 0 : Regexp::IGNORECASE
        search_regex = Regexp.new(Regexp.escape(search_pattern), regex_flags)

        new_content = content.gsub(search_regex, replacement)
        replacements_made = content.scan(search_regex).size

        File.write(absolute_path, new_content)

        {
          status: "success",
          file_path: file_path,
          replacements_made: replacements_made,
          backup_created: backup ? "#{file_path}.backup" : nil
        }
      rescue StandardError => e
        { status: "error", error: e.message }
      end
    end
  end

  def register_analysis_tools
    # Tool to analyze file properties
    @server.register_tool(
      name: "analyze_file",
      description: "Analyze file properties and content statistics",
      input_schema: {
        type: "object",
        properties: {
          file_path: { type: "string", description: "Path to the file to analyze" }
        },
        required: ["file_path"]
      }
    ) do |args, _session|
      file_path = args["file_path"]

      begin
        absolute_path = File.expand_path(file_path)
        within_root = @server.roots.any? do |_uri, root|
          absolute_path.start_with?(File.expand_path(root.path))
        end

        return { status: "error", error: "File path is outside registered roots" } unless within_root

        return { status: "error", error: "File not found" } unless File.exist?(absolute_path)

        file_stat = File.stat(absolute_path)
        content = File.read(absolute_path)

        # Basic text analysis
        lines = content.lines
        words = content.split(/\s+/)
        characters = content.length

        # File type detection
        file_type = case File.extname(file_path).downcase
                    when ".rb" then "Ruby"
                    when ".py" then "Python"
                    when ".js" then "JavaScript"
                    when ".txt" then "Text"
                    when ".md" then "Markdown"
                    when ".json" then "JSON"
                    when ".yaml", ".yml" then "YAML"
                    when ".csv" then "CSV"
                    else "Unknown"
                    end

        {
          status: "success",
          file_path: file_path,
          file_type: file_type,
          size_bytes: file_stat.size,
          created_at: file_stat.ctime,
          modified_at: file_stat.mtime,
          accessed_at: file_stat.atime,
          permissions: file_stat.mode.to_s(8),
          content_analysis: {
            line_count: lines.size,
            word_count: words.size,
            character_count: characters,
            blank_lines: lines.count { |line| line.strip.empty? },
            average_line_length: lines.empty? ? 0 : (characters.to_f / lines.size).round(2)
          }
        }
      rescue StandardError => e
        { status: "error", error: e.message }
      end
    end

    # Tool to generate directory summary
    @server.register_tool(
      name: "directory_summary",
      description: "Generate a summary report for a directory",
      input_schema: {
        type: "object",
        properties: {
          directory_path: { type: "string", description: "Path to the directory" },
          recursive: { type: "boolean", description: "Include subdirectories", default: true }
        },
        required: ["directory_path"]
      }
    ) do |args, _session|
      directory_path = args["directory_path"]
      recursive = args.fetch("recursive", true)

      begin
        absolute_path = File.expand_path(directory_path)
        within_root = @server.roots.any? do |_uri, root|
          absolute_path.start_with?(File.expand_path(root.path))
        end

        return { status: "error", error: "Directory path is outside registered roots" } unless within_root

        return { status: "error", error: "Directory not found" } unless Dir.exist?(absolute_path)

        pattern = recursive ? "#{absolute_path}/**/*" : "#{absolute_path}/*"
        all_paths = Dir.glob(pattern)

        files = all_paths.select { |path| File.file?(path) }
        directories = all_paths.select { |path| File.directory?(path) }

        # File type breakdown
        file_types = files.group_by { |file| File.extname(file).downcase }
                          .transform_values(&:size)

        # Size analysis
        total_size = files.sum { |file| File.size(file) }
        largest_files = files.map { |file| [file, File.size(file)] }
                             .sort_by { |_, size| -size }
                             .first(5)

        {
          status: "success",
          directory: directory_path,
          recursive: recursive,
          summary: {
            total_files: files.size,
            total_directories: directories.size,
            total_size_bytes: total_size,
            file_types: file_types,
            largest_files: largest_files.map { |path, size| { path: path, size_bytes: size } }
          }
        }
      rescue StandardError => e
        { status: "error", error: e.message }
      end
    end
  end
end

# Run the server
if __FILE__ == $PROGRAM_NAME
  server = FileOperationsServer.new
  server.run
end
