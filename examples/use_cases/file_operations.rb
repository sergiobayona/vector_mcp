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

# Run the server
if __FILE__ == $PROGRAM_NAME
  server = FileOperationsServer.new
  server.run
end
