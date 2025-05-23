#!/usr/bin/env ruby
# frozen_string_literal: true

# Example demonstrating VectorMCP Roots functionality
# This shows how to register filesystem roots that define boundaries
# where the MCP server can operate.

require_relative "../lib/vector_mcp"

# Set debug logging level for development
VectorMCP.logger.level = Logger::INFO

# Create a server instance
server = VectorMCP.new(name: "VectorMCP::RootsDemo", version: "0.0.1")

# Register multiple roots to define workspace boundaries
begin
  # Register current directory as a root
  server.register_root_from_path(".", name: "VectorMCP Project")

  # Register examples directory specifically
  server.register_root_from_path("./examples", name: "Examples")

  # Register lib directory
  server.register_root_from_path("./lib", name: "Library Code")

  puts "Successfully registered #{server.roots.size} roots:"
  server.roots.each do |uri, root|
    puts "  - #{root.name}: #{uri}"
  end

  # Demo tool that lists files in registered roots
  server.register_tool(
    name: "list_root_contents",
    description: "Lists the contents of a registered root directory",
    input_schema: {
      type: "object",
      properties: {
        root_uri: {
          type: "string",
          description: "URI of the root to list (must be a registered root)"
        }
      },
      required: ["root_uri"]
    }
  ) do |args, _session|
    root_uri = args["root_uri"]

    # Verify the root is registered
    root = server.roots[root_uri]
    raise ArgumentError, "Root '#{root_uri}' is not registered" unless root

    # Get the filesystem path
    path = root.path

    # List directory contents
    entries = Dir.entries(path).reject { |entry| entry.start_with?(".") }

    {
      root_name: root.name,
      root_uri: root_uri,
      path: path,
      contents: entries.sort,
      total_items: entries.size
    }
  end

  # Demo resource that provides information about registered roots
  server.register_resource(
    uri: "roots://summary",
    name: "Roots Summary",
    description: "Summary of all registered roots and their information",
    mime_type: "application/json"
  ) do |_params|
    summary = {
      total_roots: server.roots.size,
      roots: server.roots.map do |uri, root|
        {
          uri: uri,
          name: root.name,
          path: root.path,
          exists: File.exist?(root.path),
          readable: File.readable?(root.path),
          files_count: begin
            Dir.entries(root.path).reject { |f| f.start_with?(".") }.size
          rescue StandardError
            "unknown"
          end
        }
      end
    }

    JSON.pretty_generate(summary)
  end

  puts "\nServer capabilities:"
  capabilities = server.server_capabilities
  capabilities.each do |capability, details|
    puts "  - #{capability}: #{details}"
  end
rescue StandardError => e
  puts "Error setting up roots: #{e.message}"
  puts "This is normal if running from a different directory"

  # Fallback: register a temporary directory
  require "tmpdir"
  temp_dir = Dir.mktmpdir("vectormcp_roots_demo")

  # Create some demo files
  File.write(File.join(temp_dir, "readme.txt"), "This is a demo root directory")
  subdir = File.join(temp_dir, "subdir")
  Dir.mkdir(subdir)
  File.write(File.join(subdir, "example.txt"), "Example file in subdirectory")

  server.register_root_from_path(temp_dir, name: "Demo Root")

  puts "Created temporary demo root: #{temp_dir}"
  puts "Registered #{server.roots.size} root(s)"

  at_exit { FileUtils.rm_rf(temp_dir) }
end

puts "\nStarting server with roots support..."
puts "Try these requests:"
puts "  - roots/list (to see all roots)"
puts "  - tools/call with list_root_contents"
puts "  - resources/read with uri 'roots://summary'"

# Start the server
server.run # By default uses stdio transport
