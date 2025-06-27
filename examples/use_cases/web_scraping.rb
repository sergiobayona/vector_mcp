#!/usr/bin/env ruby
# frozen_string_literal: true

# Web Scraping Use Case Example
# Demonstrates intelligent web content extraction and processing with VectorMCP
#
# This example shows how to:
# - Extract content from web pages intelligently
# - Handle rate limiting and respectful scraping
# - Process structured and unstructured data
# - Extract specific data patterns (prices, contacts, etc.)
# - Generate reports from scraped content

require_relative "../../../lib/vector_mcp"
require "net/http"
require "uri"
require "json"

class WebScrapingServer
  def initialize
    @server = VectorMCP::Server.new("WebScraping")
    @scraped_data = {}
    @scraping_jobs = {}
    configure_logging
    setup_workspace
    register_scraping_tools
    register_extraction_tools
    register_processing_tools
  end

  def run
    puts "🌐 VectorMCP Web Scraping Server"
    puts "🔍 Intelligent content extraction and processing"
    puts "⚡ Respectful scraping with rate limiting"
    puts
    puts "🚀 Server starting on stdio transport..."
    puts "💡 Try calling tools like 'extract_content', 'scrape_links', or 'extract_data_patterns'"
    puts

    @server.run(transport: :stdio)
  end

  private

  def configure_logging
    @logger = VectorMCP.logger_for("web_scraping")
  end

  def setup_workspace
    @workspace_dir = File.join(__dir__, "scraping_workspace")
    Dir.mkdir(@workspace_dir) unless Dir.exist?(@workspace_dir)
    @server.register_root_from_path(@workspace_dir, name: "Scraping Workspace")
    
    # Rate limiting state
    @last_request_time = {}
    @default_delay = 1.0 # seconds between requests to same domain
  end

  def register_scraping_tools
    # Tool to extract content from web pages
    @server.register_tool(
      name: "extract_content",
      description: "Extract text content from a web page URL",
      input_schema: {
        type: "object",
        properties: {
          url: { type: "string", description: "URL to extract content from" },
          selector: { type: "string", description: "CSS selector to target specific content (optional)" },
          max_length: { type: "integer", description: "Maximum content length in characters", default: 10000 },
          respect_robots: { type: "boolean", description: "Check robots.txt before scraping", default: true }
        },
        required: ["url"]
      }
    ) do |args, session|
      url = args["url"]
      selector = args["selector"]
      max_length = args.fetch("max_length", 10000)
      respect_robots = args.fetch("respect_robots", true)

      @logger.info("Extracting content", url: url, selector: selector)

      begin
        uri = URI.parse(url)
        
        # Rate limiting
        domain = uri.host
        last_time = @last_request_time[domain]
        if last_time && (Time.now - last_time) < @default_delay
          sleep(@default_delay - (Time.now - last_time))
        end
        @last_request_time[domain] = Time.now

        # Simple robots.txt check (basic implementation)
        if respect_robots
          robots_url = "#{uri.scheme}://#{uri.host}/robots.txt"
          begin
            robots_response = Net::HTTP.get_response(URI.parse(robots_url))
            if robots_response.is_a?(Net::HTTPSuccess)
              robots_content = robots_response.body
              if robots_content.include?("Disallow: #{uri.path}") || 
                 robots_content.include?("Disallow: /")
                return { 
                  status: "error", 
                  error: "Scraping disallowed by robots.txt",
                  robots_txt: robots_content.lines.first(10).join
                }
              end
            end
          rescue
            # Continue if robots.txt check fails
          end
        end

        # Fetch the page
        response = Net::HTTP.get_response(uri)
        
        unless response.is_a?(Net::HTTPSuccess)
          return { status: "error", error: "HTTP #{response.code}: #{response.message}" }
        end

        content = response.body
        
        # Basic HTML parsing (simplified - would use Nokogiri in real implementation)
        if selector
          # Simple text extraction for demonstration
          text_content = extract_text_content(content)
        else
          text_content = extract_text_content(content)
        end

        # Truncate if too long
        if text_content.length > max_length
          text_content = text_content[0, max_length] + "... (truncated)"
        end

        # Store scraped data
        job_id = "scrape_#{Time.now.to_i}_#{rand(1000)}"
        @scraped_data[job_id] = {
          url: url,
          scraped_at: Time.now,
          content: text_content,
          response_code: response.code,
          content_type: response['content-type']
        }

        {
          status: "success",
          job_id: job_id,
          url: url,
          content_length: text_content.length,
          content: text_content,
          response_code: response.code,
          content_type: response['content-type']
        }
      rescue => e
        @logger.error("Failed to extract content", url: url, error: e.message)
        { status: "error", error: e.message }
      end
    end

    # Tool to scrape multiple links from a page
    @server.register_tool(
      name: "scrape_links",
      description: "Extract all links from a web page",
      input_schema: {
        type: "object",
        properties: {
          url: { type: "string", description: "URL to extract links from" },
          filter_domain: { type: "boolean", description: "Only return links from same domain", default: false },
          max_links: { type: "integer", description: "Maximum number of links to return", default: 100 }
        },
        required: ["url"]
      }
    ) do |args, session|
      url = args["url"]
      filter_domain = args.fetch("filter_domain", false)
      max_links = args.fetch("max_links", 100)

      begin
        uri = URI.parse(url)
        
        # Rate limiting
        domain = uri.host
        last_time = @last_request_time[domain]
        if last_time && (Time.now - last_time) < @default_delay
          sleep(@default_delay - (Time.now - last_time))
        end
        @last_request_time[domain] = Time.now

        response = Net::HTTP.get_response(uri)
        
        unless response.is_a?(Net::HTTPSuccess)
          return { status: "error", error: "HTTP #{response.code}: #{response.message}" }
        end

        content = response.body
        links = extract_links(content, uri, filter_domain)
        
        # Limit results
        links = links.first(max_links)

        {
          status: "success",
          url: url,
          total_links: links.size,
          links: links,
          filter_domain: filter_domain
        }
      rescue => e
        { status: "error", error: e.message }
      end
    end

    # Tool to check website status
    @server.register_tool(
      name: "check_website_status",
      description: "Check if a website is accessible and get basic info",
      input_schema: {
        type: "object",
        properties: {
          url: { type: "string", description: "URL to check" }
        },
        required: ["url"]
      }
    ) do |args, session|
      url = args["url"]

      begin
        uri = URI.parse(url)
        start_time = Time.now
        
        response = Net::HTTP.get_response(uri)
        response_time = Time.now - start_time

        {
          status: "success",
          url: url,
          http_status: response.code.to_i,
          http_message: response.message,
          response_time_ms: (response_time * 1000).round(2),
          content_type: response['content-type'],
          content_length: response['content-length']&.to_i,
          server: response['server'],
          accessible: response.is_a?(Net::HTTPSuccess)
        }
      rescue => e
        {
          status: "success",
          url: url,
          accessible: false,
          error: e.message
        }
      end
    end
  end

  def register_extraction_tools
    # Tool to extract specific data patterns
    @server.register_tool(
      name: "extract_data_patterns",
      description: "Extract specific patterns like emails, phone numbers, or prices from scraped content",
      input_schema: {
        type: "object",
        properties: {
          job_id: { type: "string", description: "Job ID from previous scraping operation" },
          pattern_type: { 
            type: "string", 
            enum: ["email", "phone", "price", "url", "custom"],
            description: "Type of pattern to extract" 
          },
          custom_regex: { type: "string", description: "Custom regex pattern (required if pattern_type is 'custom')" }
        },
        required: ["job_id", "pattern_type"]
      }
    ) do |args, session|
      job_id = args["job_id"]
      pattern_type = args["pattern_type"]
      custom_regex = args["custom_regex"]

      scraped = @scraped_data[job_id]
      return { status: "error", error: "Job ID not found" } unless scraped

      content = scraped[:content]
      patterns = {
        "email" => /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b/,
        "phone" => /\b(?:\+?1[-.\s]?)?\(?([0-9]{3})\)?[-.\s]?([0-9]{3})[-.\s]?([0-9]{4})\b/,
        "price" => /\$\d+(?:\.\d{2})?|\d+(?:\.\d{2})?\s*(?:USD|dollars?)/i,
        "url" => /https?:\/\/[^\s<>"{}|\\^`[\]]+/
      }

      regex = if pattern_type == "custom"
                return { status: "error", error: "custom_regex required for custom pattern" } unless custom_regex
                Regexp.new(custom_regex)
              else
                patterns[pattern_type]
              end

      matches = content.scan(regex).flatten.uniq

      {
        status: "success",
        job_id: job_id,
        pattern_type: pattern_type,
        matches_found: matches.size,
        matches: matches
      }
    end

    # Tool to extract structured data
    @server.register_tool(
      name: "extract_structured_data",
      description: "Extract structured data like tables or lists from scraped content",
      input_schema: {
        type: "object",
        properties: {
          job_id: { type: "string", description: "Job ID from previous scraping operation" },
          data_type: { 
            type: "string", 
            enum: ["table", "list", "headings"],
            description: "Type of structured data to extract" 
          }
        },
        required: ["job_id", "data_type"]
      }
    ) do |args, session|
      job_id = args["job_id"]
      data_type = args["data_type"]

      scraped = @scraped_data[job_id]
      return { status: "error", error: "Job ID not found" } unless scraped

      content = scraped[:content]
      
      # Basic extraction (would be more sophisticated with proper HTML parser)
      extracted_data = case data_type
                      when "table"
                        extract_tables(content)
                      when "list"
                        extract_lists(content)
                      when "headings"
                        extract_headings(content)
                      end

      {
        status: "success",
        job_id: job_id,
        data_type: data_type,
        items_found: extracted_data.size,
        data: extracted_data
      }
    end
  end

  def register_processing_tools
    # Tool to save scraped data
    @server.register_tool(
      name: "save_scraped_data",
      description: "Save scraped data to a file",
      input_schema: {
        type: "object",
        properties: {
          job_id: { type: "string", description: "Job ID from scraping operation" },
          filename: { type: "string", description: "Output filename" },
          format: { type: "string", enum: ["json", "text"], description: "Output format", default: "json" }
        },
        required: ["job_id", "filename"]
      }
    ) do |args, session|
      job_id = args["job_id"]
      filename = args["filename"]
      format = args.fetch("format", "json")

      scraped = @scraped_data[job_id]
      return { status: "error", error: "Job ID not found" } unless scraped

      output_path = File.join(@workspace_dir, filename)

      begin
        case format
        when "json"
          File.write(output_path, JSON.pretty_generate(scraped))
        when "text"
          File.write(output_path, scraped[:content])
        end

        {
          status: "success",
          job_id: job_id,
          saved_to: output_path,
          format: format,
          file_size: File.size(output_path)
        }
      rescue => e
        { status: "error", error: e.message }
      end
    end

    # Tool to generate scraping report
    @server.register_tool(
      name: "generate_scraping_report",
      description: "Generate a summary report of all scraping activities",
      input_schema: {
        type: "object",
        properties: {
          include_content: { type: "boolean", description: "Include scraped content in report", default: false }
        }
      }
    ) do |args, session|
      include_content = args.fetch("include_content", false)

      report = {
        generated_at: Time.now,
        total_jobs: @scraped_data.size,
        jobs: @scraped_data.map do |job_id, data|
          job_summary = {
            job_id: job_id,
            url: data[:url],
            scraped_at: data[:scraped_at],
            content_length: data[:content].length,
            response_code: data[:response_code],
            content_type: data[:content_type]
          }
          
          if include_content
            job_summary[:content] = data[:content]
          end
          
          job_summary
        end
      }

      {
        status: "success",
        report: report
      }
    end
  end

  # Helper methods for content extraction
  def extract_text_content(html)
    # Simple HTML tag removal (would use proper HTML parser in production)
    text = html.gsub(/<script[^>]*>.*?<\/script>/mi, '')
                .gsub(/<style[^>]*>.*?<\/style>/mi, '')
                .gsub(/<[^>]+>/, ' ')
                .gsub(/\s+/, ' ')
                .strip
    
    # Decode common HTML entities
    text.gsub('&amp;', '&')
        .gsub('&lt;', '<')
        .gsub('&gt;', '>')
        .gsub('&quot;', '"')
        .gsub('&#39;', "'")
  end

  def extract_links(html, base_uri, filter_domain = false)
    links = []
    
    # Simple regex to find href attributes (would use proper HTML parser in production)
    html.scan(/href=['"]([^'"]+)['"]/i) do |match|
      href = match[0]
      
      # Convert relative URLs to absolute
      begin
        link_uri = URI.join(base_uri, href)
        
        # Filter by domain if requested
        if filter_domain
          next unless link_uri.host == base_uri.host
        end
        
        links << {
          url: link_uri.to_s,
          text: href,
          domain: link_uri.host
        }
      rescue
        # Skip invalid URLs
      end
    end
    
    links.uniq { |link| link[:url] }
  end

  def extract_tables(html)
    # Basic table extraction (simplified)
    tables = []
    html.scan(/<table[^>]*>(.*?)<\/table>/mi) do |table_content|
      rows = table_content[0].scan(/<tr[^>]*>(.*?)<\/tr>/mi).map do |row_content|
        row_content[0].scan(/<t[hd][^>]*>(.*?)<\/t[hd]>/mi).map do |cell_content|
          extract_text_content(cell_content[0]).strip
        end
      end
      tables << rows unless rows.empty?
    end
    tables
  end

  def extract_lists(html)
    lists = []
    
    # Extract ordered and unordered lists
    html.scan(/<[ou]l[^>]*>(.*?)<\/[ou]l>/mi) do |list_content|
      items = list_content[0].scan(/<li[^>]*>(.*?)<\/li>/mi).map do |item_content|
        extract_text_content(item_content[0]).strip
      end
      lists << items unless items.empty?
    end
    
    lists
  end

  def extract_headings(html)
    headings = []
    
    (1..6).each do |level|
      html.scan(/<h#{level}[^>]*>(.*?)<\/h#{level}>/mi) do |heading_content|
        text = extract_text_content(heading_content[0]).strip
        headings << { level: level, text: text } unless text.empty?
      end
    end
    
    headings.sort_by { |h| h[:level] }
  end
end

# Run the server
if __FILE__ == $PROGRAM_NAME
  server = WebScrapingServer.new
  server.run
end
