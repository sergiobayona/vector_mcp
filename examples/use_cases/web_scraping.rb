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
    VectorMCP.configure_logging do
      level "INFO"
      component "web.scraping", level: "DEBUG"
      component "web.extraction", level: "INFO"
    end
  end

  def setup_workspace
    # Create workspace for scraped content
    current_dir = File.expand_path(".")
    scraping_dir = File.join(current_dir, "tmp", "web_scraping")
    FileUtils.mkdir_p(scraping_dir)
    @server.register_root_from_path(scraping_dir, name: "Scraping Workspace")
  end

  def register_scraping_tools
    # Extract content from a single web page
    @server.register_tool(
      name: "extract_content",
      description: "Extract content from a web page with intelligent parsing",
      input_schema: {
        type: "object",
        properties: {
          url: {
            type: "string",
            format: "uri",
            description: "URL of the web page to extract content from"
          },
          extract_type: {
            type: "string",
            enum: %w[full_content main_content title_only metadata links images],
            default: "main_content",
            description: "Type of content to extract"
          },
          remove_ads: {
            type: "boolean",
            default: true,
            description: "Remove advertising and promotional content"
          },
          remove_navigation: {
            type: "boolean",
            default: true,
            description: "Remove navigation menus and sidebars"
          },
          user_agent: {
            type: "string",
            description: "Custom User-Agent string for the request"
          },
          headers: {
            type: "object",
            description: "Additional HTTP headers"
          }
        },
        required: ["url"],
        additionalProperties: false
      }
    ) do |arguments, _session_context|
      url = arguments["url"]
      extract_type = arguments["extract_type"] || "main_content"
      remove_ads = arguments["remove_ads"] != false
      remove_navigation = arguments["remove_navigation"] != false
      user_agent = arguments["user_agent"]
      headers = arguments["headers"] || {}

      begin
        # Validate URL
        uri = URI(url)
        return { success: false, error: "Only HTTP and HTTPS URLs are supported" } unless %w[http https].include?(uri.scheme)

        # Fetch page content
        page_content = fetch_page(url, user_agent, headers)

        # Extract based on type
        extracted = case extract_type
                    when "full_content"
                      extract_full_content(page_content, remove_ads, remove_navigation)
                    when "main_content"
                      extract_main_content(page_content, remove_ads, remove_navigation)
                    when "title_only"
                      extract_title(page_content)
                    when "metadata"
                      extract_metadata(page_content)
                    when "links"
                      extract_links(page_content, url)
                    when "images"
                      extract_images(page_content, url)
                    end

        # Store extracted content
        content_id = generate_content_id(url)
        @scraped_data[content_id] = {
          url: url,
          content: extracted,
          extracted_at: Time.now.iso8601,
          extract_type: extract_type
        }

        {
          success: true,
          content_id: content_id,
          url: url,
          extract_type: extract_type,
          content: extracted,
          extracted_at: Time.now.iso8601
        }
      rescue StandardError => e
        { success: false, error: "Content extraction failed: #{e.message}" }
      end
    end

    # Scrape multiple pages with pattern matching
    @server.register_tool(
      name: "scrape_multiple_pages",
      description: "Scrape multiple pages following links or patterns",
      input_schema: {
        type: "object",
        properties: {
          base_url: {
            type: "string",
            format: "uri",
            description: "Starting URL or base URL pattern"
          },
          link_pattern: {
            type: "string",
            description: "Regex pattern for links to follow"
          },
          max_pages: {
            type: "integer",
            minimum: 1,
            maximum: 100,
            default: 10,
            description: "Maximum number of pages to scrape"
          },
          delay: {
            type: "number",
            minimum: 0.5,
            maximum: 10,
            default: 1,
            description: "Delay between requests in seconds"
          },
          extract_type: {
            type: "string",
            enum: %w[main_content title_only metadata],
            default: "main_content",
            description: "Type of content to extract from each page"
          },
          follow_depth: {
            type: "integer",
            minimum: 1,
            maximum: 3,
            default: 1,
            description: "Depth of link following"
          }
        },
        required: ["base_url"],
        additionalProperties: false
      }
    ) do |arguments, _session_context|
      base_url = arguments["base_url"]
      link_pattern = arguments["link_pattern"]
      max_pages = arguments["max_pages"] || 10
      delay = arguments["delay"] || 1
      extract_type = arguments["extract_type"] || "main_content"
      follow_depth = arguments["follow_depth"] || 1

      begin
        job_id = generate_job_id
        @scraping_jobs[job_id] = {
          status: "running",
          started_at: Time.now.iso8601,
          pages_scraped: 0,
          max_pages: max_pages
        }

        # Start scraping process
        results = scrape_multiple_pages_worker(
          base_url: base_url,
          link_pattern: link_pattern,
          max_pages: max_pages,
          delay: delay,
          extract_type: extract_type,
          follow_depth: follow_depth,
          job_id: job_id
        )

        @scraping_jobs[job_id][:status] = "completed"
        @scraping_jobs[job_id][:completed_at] = Time.now.iso8601
        @scraping_jobs[job_id][:results] = results

        {
          success: true,
          job_id: job_id,
          pages_scraped: results.size,
          results: results
        }
      rescue StandardError => e
        @scraping_jobs[job_id][:status] = "failed" if job_id
        @scraping_jobs[job_id][:error] = e.message if job_id
        { success: false, error: "Multi-page scraping failed: #{e.message}" }
      end
    end

    # Extract specific data patterns
    @server.register_tool(
      name: "extract_data_patterns",
      description: "Extract specific data patterns like prices, emails, phone numbers",
      input_schema: {
        type: "object",
        properties: {
          url: {
            type: "string",
            format: "uri",
            description: "URL of the web page to analyze"
          },
          patterns: {
            type: "array",
            items: {
              type: "string",
              enum: %w[prices emails phone_numbers addresses social_media product_info contact_info dates]
            },
            description: "Types of data patterns to extract"
          },
          custom_patterns: {
            type: "object",
            description: "Custom regex patterns to search for"
          }
        },
        required: %w[url patterns],
        additionalProperties: false
      }
    ) do |arguments, _session_context|
      url = arguments["url"]
      patterns = arguments["patterns"]
      custom_patterns = arguments["custom_patterns"] || {}

      begin
        # Fetch page content
        page_content = fetch_page(url)
        extracted_patterns = {}

        patterns.each do |pattern_type|
          extracted_patterns[pattern_type] = case pattern_type
                                             when "prices"
                                               extract_prices(page_content)
                                             when "emails"
                                               extract_emails(page_content)
                                             when "phone_numbers"
                                               extract_phone_numbers(page_content)
                                             when "addresses"
                                               extract_addresses(page_content)
                                             when "social_media"
                                               extract_social_media_links(page_content)
                                             when "product_info"
                                               extract_product_info(page_content)
                                             when "contact_info"
                                               extract_contact_info(page_content)
                                             when "dates"
                                               extract_dates(page_content)
                                             end
        end

        # Process custom patterns
        custom_patterns.each do |name, regex|
          extracted_patterns[name] = extract_custom_pattern(page_content, regex)
        end

        {
          success: true,
          url: url,
          patterns: extracted_patterns,
          extracted_at: Time.now.iso8601
        }
      rescue StandardError => e
        { success: false, error: "Pattern extraction failed: #{e.message}" }
      end
    end

    # Monitor for content changes
    @server.register_tool(
      name: "monitor_changes",
      description: "Monitor a web page for content changes",
      input_schema: {
        type: "object",
        properties: {
          url: {
            type: "string",
            format: "uri",
            description: "URL to monitor for changes"
          },
          selector: {
            type: "string",
            description: "CSS selector or XPath to monitor specific content"
          },
          interval: {
            type: "integer",
            minimum: 60,
            maximum: 86_400,
            default: 300,
            description: "Check interval in seconds"
          },
          threshold: {
            type: "number",
            minimum: 0.1,
            maximum: 1.0,
            default: 0.1,
            description: "Minimum change threshold (0.1 = 10% change)"
          }
        },
        required: ["url"],
        additionalProperties: false
      }
    ) do |arguments, _session_context|
      url = arguments["url"]
      selector = arguments["selector"]
      interval = arguments["interval"] || 300
      threshold = arguments["threshold"] || 0.1

      begin
        # Get baseline content
        baseline_content = fetch_page(url)
        baseline_hash = content_hash(baseline_content, selector)

        monitor_id = generate_monitor_id

        # In a real implementation, this would set up background monitoring
        # For this example, we'll just return the setup information
        {
          success: true,
          monitor_id: monitor_id,
          url: url,
          baseline_hash: baseline_hash,
          interval: interval,
          threshold: threshold,
          status: "active",
          created_at: Time.now.iso8601
        }
      rescue StandardError => e
        { success: false, error: "Monitor setup failed: #{e.message}" }
      end
    end
  end

  def register_extraction_tools
    # Extract structured data from tables
    @server.register_tool(
      name: "extract_tables",
      description: "Extract structured data from HTML tables",
      input_schema: {
        type: "object",
        properties: {
          url: {
            type: "string",
            format: "uri",
            description: "URL containing tables to extract"
          },
          table_index: {
            type: "integer",
            minimum: 0,
            description: "Specific table index to extract (0-based)"
          },
          headers: {
            type: "boolean",
            default: true,
            description: "Whether the table has headers"
          },
          format: {
            type: "string",
            enum: %w[json csv array],
            default: "json",
            description: "Output format for the table data"
          }
        },
        required: ["url"],
        additionalProperties: false
      }
    ) do |arguments, _session_context|
      url = arguments["url"]
      table_index = arguments["table_index"]
      has_headers = arguments["headers"] != false
      format = arguments["format"] || "json"

      begin
        page_content = fetch_page(url)
        tables = extract_html_tables(page_content, has_headers)

        if table_index
          return { success: false, error: "Table index #{table_index} not found" } if table_index >= tables.size

          result_tables = [tables[table_index]]
        else
          result_tables = tables
        end

        formatted_tables = result_tables.map do |table|
          case format
          when "json"
            table
          when "csv"
            convert_table_to_csv(table)
          when "array"
            convert_table_to_array(table)
          end
        end

        {
          success: true,
          url: url,
          tables_found: tables.size,
          tables: table_index ? formatted_tables.first : formatted_tables,
          format: format,
          extracted_at: Time.now.iso8601
        }
      rescue StandardError => e
        { success: false, error: "Table extraction failed: #{e.message}" }
      end
    end

    # Extract form data and structure
    @server.register_tool(
      name: "extract_forms",
      description: "Extract form structure and fields from web pages",
      input_schema: {
        type: "object",
        properties: {
          url: {
            type: "string",
            format: "uri",
            description: "URL containing forms to analyze"
          }
        },
        required: ["url"],
        additionalProperties: false
      }
    ) do |arguments, _session_context|
      url = arguments["url"]

      begin
        page_content = fetch_page(url)
        forms = extract_html_forms(page_content)

        {
          success: true,
          url: url,
          forms_found: forms.size,
          forms: forms,
          extracted_at: Time.now.iso8601
        }
      rescue StandardError => e
        { success: false, error: "Form extraction failed: #{e.message}" }
      end
    end
  end

  def register_processing_tools
    # Clean and process scraped content
    @server.register_tool(
      name: "process_content",
      description: "Clean and process scraped content",
      input_schema: {
        type: "object",
        properties: {
          content_id: {
            type: "string",
            description: "ID of previously scraped content"
          },
          operations: {
            type: "array",
            items: {
              type: "string",
              enum: %w[remove_html clean_text extract_keywords summarize translate normalize_whitespace]
            },
            description: "Processing operations to apply"
          },
          options: {
            type: "object",
            description: "Options for specific operations"
          }
        },
        required: %w[content_id operations],
        additionalProperties: false
      }
    ) do |arguments, _session_context|
      content_id = arguments["content_id"]
      operations = arguments["operations"]
      options = arguments["options"] || {}

      scraped_content = @scraped_data[content_id]
      return { success: false, error: "Content not found: #{content_id}" } unless scraped_content

      begin
        processed_content = scraped_content[:content].dup

        operations.each do |operation|
          processed_content = case operation
                              when "remove_html"
                                remove_html_tags(processed_content)
                              when "clean_text"
                                clean_text(processed_content)
                              when "extract_keywords"
                                extract_keywords(processed_content, options["keyword_count"] || 10)
                              when "summarize"
                                summarize_text(processed_content, options["max_sentences"] || 3)
                              when "translate"
                                translate_text(processed_content, options["target_language"] || "en")
                              when "normalize_whitespace"
                                normalize_whitespace(processed_content)
                              else
                                processed_content
                              end
        end

        {
          success: true,
          content_id: content_id,
          original_content: scraped_content[:content],
          processed_content: processed_content,
          operations_applied: operations,
          processed_at: Time.now.iso8601
        }
      rescue StandardError => e
        { success: false, error: "Content processing failed: #{e.message}" }
      end
    end

    # Export scraped data
    @server.register_tool(
      name: "export_scraped_data",
      description: "Export all scraped data to various formats",
      input_schema: {
        type: "object",
        properties: {
          format: {
            type: "string",
            enum: %w[json csv excel html],
            default: "json",
            description: "Export format"
          },
          include_metadata: {
            type: "boolean",
            default: true,
            description: "Include extraction metadata"
          },
          filter: {
            type: "object",
            description: "Filter criteria for export"
          }
        },
        additionalProperties: false
      }
    ) do |arguments, _session_context|
      format = arguments["format"] || "json"
      include_metadata = arguments["include_metadata"] != false
      filter = arguments["filter"] || {}

      begin
        # Apply filters
        filtered_data = @scraped_data
        if filter["url_pattern"]
          regex = Regexp.new(filter["url_pattern"])
          filtered_data = filtered_data.select { |_, data| data[:url] =~ regex }
        end

        filtered_data = filtered_data.select { |_, data| data[:extract_type] == filter["extract_type"] } if filter["extract_type"]

        # Export data
        exported_data = export_data(filtered_data, format, include_metadata)

        # Save to file
        timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
        filename = "scraped_data_#{timestamp}.#{format}"
        output_path = save_export(exported_data, filename, format)

        {
          success: true,
          format: format,
          records_exported: filtered_data.size,
          output_path: output_path,
          file_size: File.size(output_path),
          exported_at: Time.now.iso8601
        }
      rescue StandardError => e
        { success: false, error: "Export failed: #{e.message}" }
      end
    end

    # Generate scraping report
    @server.register_tool(
      name: "generate_scraping_report",
      description: "Generate comprehensive report of scraping activities",
      input_schema: {
        type: "object",
        properties: {
          format: {
            type: "string",
            enum: %w[markdown html text],
            default: "markdown",
            description: "Report format"
          },
          include_samples: {
            type: "boolean",
            default: true,
            description: "Include sample content in report"
          }
        },
        additionalProperties: false
      }
    ) do |arguments, _session_context|
      format = arguments["format"] || "markdown"
      include_samples = arguments["include_samples"] != false

      begin
        report = generate_comprehensive_scraping_report(format, include_samples)

        # Save report
        timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
        filename = "scraping_report_#{timestamp}.#{format}"
        output_path = save_report(report, filename)

        {
          success: true,
          report: report,
          format: format,
          output_path: output_path,
          generated_at: Time.now.iso8601
        }
      rescue StandardError => e
        { success: false, error: "Report generation failed: #{e.message}" }
      end
    end
  end

  # Helper methods for web scraping

  def fetch_page(url, user_agent = nil, headers = {})
    uri = URI(url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 10
    http.read_timeout = 30

    request = Net::HTTP::Get.new(uri)
    request["User-Agent"] = user_agent || "VectorMCP WebScraper/1.0"

    headers.each { |key, value| request[key] = value }

    response = http.request(request)

    raise "HTTP #{response.code}: #{response.message}" unless response.code.start_with?("2")

    response.body
  end

  def extract_full_content(html, remove_ads, remove_navigation)
    content = html.dup

    if remove_ads
      # Simple ad removal patterns
      content = remove_ad_content(content)
    end

    content = remove_navigation_content(content) if remove_navigation

    content
  end

  def extract_main_content(html, remove_ads, remove_navigation)
    content = extract_full_content(html, remove_ads, remove_navigation)

    # Extract main content using simple heuristics
    # In a real implementation, this would use more sophisticated algorithms
    main_content_patterns = [
      %r{<article[^>]*>(.*?)</article>}mi,
      %r{<main[^>]*>(.*?)</main>}mi,
      %r{<div[^>]*class="[^"]*content[^"]*"[^>]*>(.*?)</div>}mi,
      %r{<div[^>]*id="[^"]*content[^"]*"[^>]*>(.*?)</div>}mi
    ]

    main_content_patterns.each do |pattern|
      match = content.match(pattern)
      return clean_html_content(match[1]) if match
    end

    # Fallback: extract text from body
    body_match = content.match(%r{<body[^>]*>(.*?)</body>}mi)
    return clean_html_content(body_match[1]) if body_match

    clean_html_content(content)
  end

  def extract_title(html)
    title_match = html.match(%r{<title[^>]*>(.*?)</title>}mi)
    return { title: clean_text(title_match[1]) } if title_match

    h1_match = html.match(%r{<h1[^>]*>(.*?)</h1>}mi)
    return { title: clean_html_content(h1_match[1]) } if h1_match

    { title: "No title found" }
  end

  def extract_metadata(html)
    metadata = {}

    # Extract meta tags
    html.scan(/<meta[^>]*name="([^"]*)"[^>]*content="([^"]*)"[^>]*>/i) do |name, content|
      metadata[name.downcase] = content
    end

    # Extract Open Graph tags
    html.scan(/<meta[^>]*property="og:([^"]*)"[^>]*content="([^"]*)"[^>]*>/i) do |property, content|
      metadata["og_#{property}"] = content
    end

    # Extract title
    title_data = extract_title(html)
    metadata.merge!(title_data)

    metadata
  end

  def extract_links(html, base_url)
    links = []
    base_uri = URI(base_url)

    html.scan(%r{<a[^>]*href="([^"]*)"[^>]*>(.*?)</a>}mi) do |href, text|
      next if href.start_with?("#") || href.start_with?("javascript:")

      absolute_url = if href.start_with?("http")
                       href
                     elsif href.start_with?("/")
                       "#{base_uri.scheme}://#{base_uri.host}#{href}"
                     else
                       "#{base_uri.scheme}://#{base_uri.host}#{base_uri.path}/#{href}"
                     end

      links << {
        url: absolute_url,
        text: clean_html_content(text),
        rel: extract_link_rel(html, href)
      }
    end

    links.uniq { |link| link[:url] }
  end

  def extract_images(html, base_url)
    images = []
    base_uri = URI(base_url)

    html.scan(/<img[^>]*src="([^"]*)"[^>]*>/i) do |src|
      absolute_url = if src.start_with?("http")
                       src
                     elsif src.start_with?("/")
                       "#{base_uri.scheme}://#{base_uri.host}#{src}"
                     else
                       "#{base_uri.scheme}://#{base_uri.host}#{base_uri.path}/#{src}"
                     end

      images << {
        url: absolute_url,
        alt: extract_image_alt(html, src)
      }
    end

    images.uniq { |img| img[:url] }
  end

  # Pattern extraction methods

  def extract_prices(content)
    price_patterns = [
      /\$\d+(?:\.\d{2})?/, # $19.99
      /\d+(?:\.\d{2})?\s*(?:USD|EUR|GBP)/i, # 19.99 USD
      /(?:Price|Cost):\s*\$?\d+(?:\.\d{2})?/i # Price: $19.99
    ]

    prices = []
    price_patterns.each do |pattern|
      content.scan(pattern) { |match| prices << match }
    end

    prices.flatten.uniq
  end

  def extract_emails(content)
    email_pattern = /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b/
    content.scan(email_pattern).uniq
  end

  def extract_phone_numbers(content)
    phone_patterns = [
      /\(\d{3}\)\s*\d{3}-\d{4}/,  # (555) 123-4567
      /\d{3}-\d{3}-\d{4}/,        # 555-123-4567
      /\d{3}\.\d{3}\.\d{4}/,      # 555.123.4567
      /\+1\s*\d{3}\s*\d{3}\s*\d{4}/ # +1 555 123 4567
    ]

    phones = []
    phone_patterns.each do |pattern|
      content.scan(pattern) { |match| phones << match }
    end

    phones.flatten.uniq
  end

  def extract_addresses(content)
    # Simple address pattern - would need more sophisticated parsing for real use
    address_pattern = /\d+\s+[A-Za-z\s]+(?:Street|St|Avenue|Ave|Road|Rd|Drive|Dr|Lane|Ln|Boulevard|Blvd)/i
    content.scan(address_pattern).uniq
  end

  def extract_social_media_links(content)
    social_patterns = {
      twitter: %r{(?:https?://)?(?:www\.)?twitter\.com/\w+},
      facebook: %r{(?:https?://)?(?:www\.)?facebook\.com/\w+},
      linkedin: %r{(?:https?://)?(?:www\.)?linkedin\.com/(?:in|company)/\w+},
      instagram: %r{(?:https?://)?(?:www\.)?instagram\.com/\w+}
    }

    social_links = {}
    social_patterns.each do |platform, pattern|
      matches = content.scan(pattern)
      social_links[platform] = matches.uniq unless matches.empty?
    end

    social_links
  end

  def extract_product_info(content)
    # Extract common product information patterns
    {
      names: extract_product_names(content),
      prices: extract_prices(content),
      ratings: extract_ratings(content),
      descriptions: extract_product_descriptions(content)
    }
  end

  def extract_contact_info(content)
    {
      emails: extract_emails(content),
      phones: extract_phone_numbers(content),
      addresses: extract_addresses(content),
      social_media: extract_social_media_links(content)
    }
  end

  def extract_dates(content)
    date_patterns = [
      %r{\b\d{1,2}/\d{1,2}/\d{4}\b},  # MM/DD/YYYY
      /\b\d{4}-\d{2}-\d{2}\b/,        # YYYY-MM-DD
      /\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2},?\s+\d{4}\b/i # Month DD, YYYY
    ]

    dates = []
    date_patterns.each do |pattern|
      content.scan(pattern) { |match| dates << match }
    end

    dates.flatten.uniq
  end

  def extract_custom_pattern(content, regex_pattern)
    pattern = Regexp.new(regex_pattern, Regexp::IGNORECASE)
    content.scan(pattern).flatten.uniq
  rescue RegexpError => e
    ["Invalid regex pattern: #{e.message}"]
  end

  # Content processing methods

  def scrape_multiple_pages_worker(options)
    base_url = options[:base_url]
    link_pattern = options[:link_pattern]
    max_pages = options[:max_pages]
    delay = options[:delay]
    extract_type = options[:extract_type]
    follow_depth = options[:follow_depth]
    job_id = options[:job_id]
    results = []
    visited_urls = Set.new
    urls_to_visit = [base_url]

    current_depth = 0

    while results.size < max_pages && !urls_to_visit.empty? && current_depth < follow_depth
      current_level_urls = urls_to_visit.dup
      urls_to_visit.clear

      current_level_urls.each do |url|
        break if results.size >= max_pages
        next if visited_urls.include?(url)

        begin
          # Respect rate limiting
          sleep(delay) if results.size.positive?

          visited_urls.add(url)

          # Extract content
          page_content = fetch_page(url)
          extracted = case extract_type
                      when "main_content"
                        extract_main_content(page_content, true, true)
                      when "title_only"
                        extract_title(page_content)
                      when "metadata"
                        extract_metadata(page_content)
                      end

          results << {
            url: url,
            content: extracted,
            depth: current_depth,
            extracted_at: Time.now.iso8601
          }

          # Update job status
          @scraping_jobs[job_id][:pages_scraped] = results.size

          # Find links for next depth level
          if current_depth < follow_depth - 1
            links = extract_links(page_content, url)
            if link_pattern
              pattern = Regexp.new(link_pattern)
              matching_links = links.select { |link| link[:url] =~ pattern }
              urls_to_visit.concat(matching_links.map { |link| link[:url] })
            else
              urls_to_visit.concat(links.map { |link| link[:url] })
            end
          end
        rescue StandardError => e
          # Log error but continue with other URLs
          results << {
            url: url,
            error: e.message,
            depth: current_depth,
            extracted_at: Time.now.iso8601
          }
        end
      end

      current_depth += 1
    end

    results
  end

  # HTML processing helpers

  def remove_ad_content(html)
    ad_selectors = [
      /<!--.*?ad.*?-->/mi,
      %r{<div[^>]*class="[^"]*ad[^"]*"[^>]*>.*?</div>}mi,
      %r{<div[^>]*id="[^"]*ad[^"]*"[^>]*>.*?</div>}mi,
      %r{<aside[^>]*>.*?</aside>}mi
    ]

    content = html.dup
    ad_selectors.each { |pattern| content.gsub!(pattern, "") }
    content
  end

  def remove_navigation_content(html)
    nav_selectors = [
      %r{<nav[^>]*>.*?</nav>}mi,
      %r{<div[^>]*class="[^"]*nav[^"]*"[^>]*>.*?</div>}mi,
      %r{<div[^>]*class="[^"]*menu[^"]*"[^>]*>.*?</div>}mi,
      %r{<header[^>]*>.*?</header>}mi,
      %r{<footer[^>]*>.*?</footer>}mi
    ]

    content = html.dup
    nav_selectors.each { |pattern| content.gsub!(pattern, "") }
    content
  end

  def clean_html_content(html)
    # Remove HTML tags and clean up text
    text = html.gsub(/<[^>]+>/, " ")
    clean_text(text)
  end

  def clean_text(text)
    text.gsub(/\s+/, " ").strip
  end

  def normalize_whitespace(text)
    text.gsub(/\s+/, " ").gsub(/\n\s*\n/, "\n").strip
  end

  def remove_html_tags(content)
    content.gsub(/<[^>]+>/, "")
  end

  # Utility methods

  def generate_content_id(url)
    "content_#{Digest::SHA256.hexdigest(url)[0, 8]}_#{Time.now.to_i}"
  end

  def generate_job_id
    "job_#{SecureRandom.hex(4)}_#{Time.now.to_i}"
  end

  def generate_monitor_id
    "monitor_#{SecureRandom.hex(4)}_#{Time.now.to_i}"
  end

  def content_hash(content, selector = nil)
    text_content = selector ? extract_selected_content(content, selector) : content
    Digest::SHA256.hexdigest(clean_text(text_content))
  end

  # Additional extraction methods (simplified implementations)

  def extract_html_tables(html, has_headers)
    tables = []

    html.scan(%r{<table[^>]*>(.*?)</table>}mi) do |table_content|
      rows = []

      table_content[0].scan(%r{<tr[^>]*>(.*?)</tr>}mi) do |row_content|
        cells = []
        row_content[0].scan(%r{<t[hd][^>]*>(.*?)</t[hd]>}mi) do |cell_content|
          cells << clean_html_content(cell_content[0])
        end
        rows << cells unless cells.empty?
      end

      if has_headers && !rows.empty?
        headers = rows.shift
        table_data = rows.map { |row| headers.zip(row).to_h }
        tables << table_data
      else
        tables << rows
      end
    end

    tables
  end

  def extract_html_forms(html)
    forms = []

    html.scan(%r{<form[^>]*>(.*?)</form>}mi) do |form_content|
      form_data = {
        action: extract_form_action(form_content[0]),
        method: extract_form_method(form_content[0]),
        fields: extract_form_fields(form_content[0])
      }
      forms << form_data
    end

    forms
  end

  def extract_form_action(form_html)
    match = form_html.match(/action="([^"]*)"/i)
    match ? match[1] : ""
  end

  def extract_form_method(form_html)
    match = form_html.match(/method="([^"]*)"/i)
    match ? match[1].upcase : "GET"
  end

  def extract_form_fields(form_html)
    fields = []

    # Extract input fields
    form_html.scan(/<input[^>]*>/i) do |input|
      field_data = extract_input_attributes(input)
      fields << field_data unless field_data[:type] == "hidden"
    end

    # Extract select fields
    form_html.scan(%r{<select[^>]*name="([^"]*)"[^>]*>(.*?)</select>}mi) do |name, options|
      fields << {
        type: "select",
        name: name,
        options: extract_select_options(options)
      }
    end

    # Extract textarea fields
    form_html.scan(/<textarea[^>]*name="([^"]*)"[^>]*>/i) do |name|
      fields << {
        type: "textarea",
        name: name
      }
    end

    fields
  end

  def extract_input_attributes(input_html)
    attributes = {}

    input_html.scan(/(\w+)="([^"]*)"/i) do |attr, value|
      attributes[attr.downcase.to_sym] = value
    end

    attributes
  end

  def extract_select_options(options_html)
    options = []

    options_html.scan(%r{<option[^>]*value="([^"]*)"[^>]*>(.*?)</option>}mi) do |value, text|
      options << {
        value: value,
        text: clean_html_content(text)
      }
    end

    options
  end

  # Text processing methods

  def extract_keywords(text, count)
    # Simple keyword extraction - count word frequency
    words = clean_text(text).downcase.split(/\W+/)

    # Filter out common stop words
    stop_words = %w[the and or but in on at to for of with by from a an is are was were be been being have has had will would could should may might
                    must can]

    filtered_words = words.reject { |word| stop_words.include?(word) || word.length < 3 }

    word_freq = Hash.new(0)
    filtered_words.each { |word| word_freq[word] += 1 }

    word_freq.sort_by { |_, freq| -freq }.first(count).map(&:first)
  end

  def summarize_text(text, max_sentences)
    sentences = text.split(/[.!?]+/).map(&:strip).reject(&:empty?)

    # Simple extractive summarization - take first N sentences
    "#{sentences.first(max_sentences).join(". ")}."
  end

  def translate_text(text, target_language)
    # Placeholder for translation - would integrate with translation service
    "[Translated to #{target_language}] #{text}"
  end

  # Export and reporting methods

  def export_data(data, format, include_metadata)
    case format
    when "json"
      JSON.pretty_generate(data)
    when "csv"
      export_to_csv(data, include_metadata)
    when "html"
      export_to_html(data, include_metadata)
    else
      data.to_s
    end
  end

  def export_to_csv(data, include_metadata)
    require "csv"

    CSV.generate do |csv|
      # Header row
      headers = ["Content ID", "URL", "Extract Type", "Extracted At"]
      headers += ["Content"] unless include_metadata
      csv << headers

      data.each do |content_id, content_data|
        row = [
          content_id,
          content_data[:url],
          content_data[:extract_type],
          content_data[:extracted_at]
        ]

        unless include_metadata
          content_text = if content_data[:content].is_a?(Hash)
                           content_data[:content].to_json
                         else
                           content_data[:content].to_s
                         end
          row << content_text
        end

        csv << row
      end
    end
  end

  def export_to_html(data, include_metadata)
    html = ["<html><head><title>Scraped Data Export</title></head><body>"]
    html << "<h1>Scraped Data Export</h1>"
    html << "<p>Generated: #{Time.now.strftime("%Y-%m-%d %H:%M:%S")}</p>"

    data.each_value do |content_data|
      html << "<div style='border: 1px solid #ccc; margin: 10px; padding: 10px;'>"
      html << "<h3>#{content_data[:url]}</h3>"
      html << "<p><strong>Type:</strong> #{content_data[:extract_type]}</p>"
      html << "<p><strong>Extracted:</strong> #{content_data[:extracted_at]}</p>"

      if include_metadata
        html << "<pre>#{JSON.pretty_generate(content_data[:content])}</pre>"
      else
        content_text = if content_data[:content].is_a?(Hash)
                         content_data[:content].to_json
                       else
                         content_data[:content].to_s
                       end
        html << "<p>#{content_text[0, 500]}#{"..." if content_text.length > 500}</p>"
      end

      html << "</div>"
    end

    html << "</body></html>"
    html.join("\n")
  end

  def save_export(data, filename, _format)
    output_dir = File.join("tmp", "web_scraping", "exports")
    FileUtils.mkdir_p(output_dir)
    output_path = File.join(output_dir, filename)

    File.write(output_path, data)
    output_path
  end

  def save_report(report, filename)
    output_dir = File.join("tmp", "web_scraping", "reports")
    FileUtils.mkdir_p(output_dir)
    output_path = File.join(output_dir, filename)

    File.write(output_path, report)
    output_path
  end

  def generate_comprehensive_scraping_report(format, include_samples)
    case format
    when "markdown"
      generate_markdown_report(include_samples)
    when "html"
      generate_html_report(include_samples)
    else
      generate_text_report(include_samples)
    end
  end

  def generate_markdown_report(include_samples)
    md = []
    md << "# Web Scraping Report"
    md << ""
    md << "**Generated:** #{Time.now.strftime("%Y-%m-%d %H:%M:%S")}"
    md << "**Total Content Extracted:** #{@scraped_data.size} items"
    md << ""

    md << "## Summary Statistics"
    md << ""

    extract_types = @scraped_data.values.group_by { |data| data[:extract_type] }
    extract_types.each do |type, items|
      md << "- **#{type.capitalize}:** #{items.size} items"
    end

    md << ""
    md << "## Scraped URLs"
    md << ""

    @scraped_data.each_value do |data|
      md << "### #{data[:url]}"
      md << ""
      md << "- **Type:** #{data[:extract_type]}"
      md << "- **Extracted:** #{data[:extracted_at]}"
      md << ""

      next unless include_samples

      content_preview = if data[:content].is_a?(Hash)
                          JSON.pretty_generate(data[:content])
                        else
                          data[:content].to_s[0, 200]
                        end
      md << "```"
      md << content_preview
      md << "```"
      md << ""
    end

    md.join("\n")
  end

  def generate_html_report(include_samples)
    # Similar to markdown but with HTML formatting
    generate_markdown_report(include_samples).gsub(/^# (.+)$/, '<h1>\1</h1>')
                                             .gsub(/^## (.+)$/, '<h2>\1</h2>')
                                             .gsub(/^### (.+)$/, '<h3>\1</h3>')
  end

  def generate_text_report(_include_samples)
    lines = []
    lines << "WEB SCRAPING REPORT"
    lines << ("=" * 50)
    lines << "Generated: #{Time.now.strftime("%Y-%m-%d %H:%M:%S")}"
    lines << "Total Content: #{@scraped_data.size} items"
    lines << ""

    @scraped_data.each_value do |data|
      lines << "URL: #{data[:url]}"
      lines << "Type: #{data[:extract_type]}"
      lines << "Extracted: #{data[:extracted_at]}"
      lines << ("-" * 30)
    end

    lines.join("\n")
  end

  # Placeholder methods for advanced features

  def extract_product_names(content)
    # Simple product name extraction
    content.scan(/(?:Product|Item):\s*([^<\n]+)/i).flatten
  end

  def extract_ratings(content)
    content.scan(%r{(\d+(?:\.\d+)?)\s*(?:stars?|/5|rating)}i).flatten
  end

  def extract_product_descriptions(content)
    # Extract paragraphs that might be descriptions
    content.scan(%r{<p[^>]*>(.*?)</p>}mi).map { |match| clean_html_content(match[0]) }.select { |text| text.length > 50 }
  end

  def extract_link_rel(html, href)
    # Extract rel attribute for links
    match = html.match(/<a[^>]*href="#{Regexp.escape(href)}"[^>]*rel="([^"]*)"/)
    match ? match[1] : nil
  end

  def extract_image_alt(html, src)
    # Extract alt text for images
    match = html.match(/<img[^>]*src="#{Regexp.escape(src)}"[^>]*alt="([^"]*)"/)
    match ? match[1] : nil
  end

  def extract_selected_content(content, _selector)
    # Placeholder for CSS/XPath selector support
    content
  end

  def convert_table_to_csv(table_data)
    require "csv"

    if table_data.first.is_a?(Hash)
      CSV.generate do |csv|
        csv << table_data.first.keys
        table_data.each { |row| csv << row.values }
      end
    else
      CSV.generate do |csv|
        table_data.each { |row| csv << row }
      end
    end
  end

  def convert_table_to_array(table_data)
    table_data.is_a?(Array) ? table_data : table_data.map(&:values)
  end
end

# Run the server
if __FILE__ == $PROGRAM_NAME
  server = WebScrapingServer.new
  server.run
end
