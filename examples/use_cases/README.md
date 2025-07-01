# 🎯 VectorMCP Real-World Use Cases

This section provides practical, production-ready examples that demonstrate how to implement common real-world scenarios using VectorMCP. These examples show complete workflows and integration patterns for typical business use cases.

## 🎯 What You'll Learn

- **File System Operations**: Secure file management and processing
- **Data Analysis Workflows**: Processing and analyzing data with AI assistance
- **Web Content Extraction**: Intelligent scraping and content processing
- **Integration Patterns**: Connecting VectorMCP with existing systems
- **Production Architectures**: Scalable, secure deployment patterns

---

## 📚 Examples Overview

### 1. [`file_operations.rb`](./file_operations.rb) 📁 **FILE MANAGEMENT**
**Comprehensive file system automation with security**

```bash
ruby examples/use_cases/file_operations.rb
```

**What it demonstrates:**
- **Secure file access**: Using filesystem roots for boundary enforcement
- **File processing tools**: Read, write, search, and analyze files
- **Content transformation**: Converting between formats (Markdown, JSON, CSV)
- **Backup and versioning**: Automated file management workflows
- **Permission management**: Role-based file access control

**Use cases:**
- **Documentation systems**: Process and organize documentation files
- **Code analysis**: Analyze source code repositories safely
- **Data migration**: Convert and transfer files between systems
- **Content management**: Organize and process content libraries
- **Backup automation**: Automated backup and recovery workflows

**Key tools:**
```ruby
# File reading with security boundaries
server.register_tool(name: "read_file") do |args|
  # Automatically respects filesystem roots
  File.read(args["path"])
end

# Intelligent file search
server.register_tool(name: "search_files") do |args|
  # Search within allowed directories only
  search_pattern(args["pattern"], args["directory"])
end

# Content transformation
server.register_tool(name: "convert_format") do |args|
  # Convert between Markdown, JSON, CSV, etc.
  convert_file(args["source"], args["target"], args["format"])
end
```

**Perfect for:** Document management, code analysis, content processing

---

### 2. [`data_analysis.rb`](./data_analysis.rb) 📊 **DATA PROCESSING**
**AI-assisted data analysis and processing workflows**

```bash
ruby examples/use_cases/data_analysis.rb
```

**What it demonstrates:**
- **Data ingestion**: Reading from CSV, JSON, APIs, databases
- **Statistical analysis**: Basic stats, correlations, trend analysis
- **Data visualization**: Generating charts and graphs
- **Report generation**: Automated reporting with AI insights
- **Data validation**: Quality checks and anomaly detection

**Use cases:**
- **Business intelligence**: Process sales, metrics, and KPI data
- **Log analysis**: Analyze application and system logs
- **Survey processing**: Process and analyze survey responses
- **Financial analysis**: Process transaction and accounting data
- **Performance monitoring**: Analyze system and application metrics

**Key tools:**
```ruby
# Data loading and validation
server.register_tool(name: "load_dataset") do |args|
  data = load_data(args["source"], args["format"])
  validate_data_quality(data)
end

# Statistical analysis
server.register_tool(name: "analyze_data") do |args|
  dataset = get_dataset(args["dataset_id"])
  {
    summary: calculate_summary_stats(dataset),
    correlations: find_correlations(dataset),
    trends: identify_trends(dataset)
  }
end

# Report generation
server.register_tool(name: "generate_report") do |args|
  template = load_report_template(args["template"])
  data = get_analysis_results(args["analysis_id"])
  generate_pdf_report(template, data)
end
```

**Perfect for:** Business analytics, data science workflows, automated reporting

---

### 3. [`web_scraping.rb`](./web_scraping.rb) 🌐 **CONTENT EXTRACTION**
**Intelligent web content extraction and processing**

```bash
ruby examples/use_cases/web_scraping.rb
```

**What it demonstrates:**
- **Smart content extraction**: AI-guided content identification
- **Structured data extraction**: Tables, lists, and form data
- **Content cleaning**: Removing ads, navigation, and noise
- **Multi-page workflows**: Following links and pagination
- **Rate limiting**: Respectful scraping with delays and throttling

**Use cases:**
- **Market research**: Extract competitor pricing and product info
- **Content aggregation**: Collect news articles and blog posts
- **Lead generation**: Extract contact information from directories
- **Price monitoring**: Track product prices across e-commerce sites
- **Social media monitoring**: Collect mentions and sentiment data

**Key tools:**
```ruby
# Intelligent content extraction
server.register_tool(name: "extract_content") do |args|
  page = fetch_page(args["url"])
  {
    title: extract_title(page),
    content: extract_main_content(page),
    metadata: extract_metadata(page),
    links: extract_links(page)
  }
end

# Structured data extraction
server.register_tool(name: "extract_table") do |args|
  page = fetch_page(args["url"])
  tables = extract_tables(page)
  convert_to_csv(tables[args["table_index"]])
end

# Multi-page workflow
server.register_tool(name: "scrape_site") do |args|
  urls = discover_pages(args["base_url"], args["pattern"])
  results = []
  
  urls.each do |url|
    sleep(args["delay"] || 1)  # Rate limiting
    results << extract_content_from_url(url)
  end
  
  results
end
```

**Perfect for:** Market research, content aggregation, competitive analysis

---

## 🏗️ Production Architecture Patterns

### 1. Microservice Integration
```ruby
# VectorMCP as a microservice
class ProductionServer
  def initialize
    @server = VectorMCP::Server.new("DataProcessor")
    configure_security
    configure_logging
    register_business_tools
  end
  
  private
  
  def configure_security
    @server.enable_authentication!(
      strategy: :jwt_token,
      secret: ENV["JWT_SECRET"]
    )
    
    @server.enable_authorization! do
      authorize_tools do |user, action, tool|
        user[:permissions].include?(tool.name) ||
        user[:role] == "admin"
      end
    end
  end
  
  def configure_logging
    VectorMCP.configure_logging do
      level ENV["LOG_LEVEL"] || "INFO"
      format "json"
      output "file"
      file_path "/var/log/vectormcp/app.log"
    end
  end
end
```

### 2. Database Integration
```ruby
# Database-backed tools
server.register_tool(name: "query_users") do |args|
  validate_sql_injection(args["query"])
  
  result = database.execute(
    "SELECT * FROM users WHERE #{safe_conditions(args)}"
  )
  
  format_query_results(result)
end

# Audit logging for database operations
server.register_tool(name: "update_record") do |args, session|
  audit_logger.info("Database update", context: {
    user_id: session.user[:id],
    table: args["table"],
    record_id: args["id"],
    operation: "update"
  })
  
  database.update(args["table"], args["id"], args["data"])
end
```

### 3. API Integration
```ruby
# External API integration
server.register_tool(name: "fetch_external_data") do |args|
  api_client = ExternalAPI.new(
    api_key: ENV["EXTERNAL_API_KEY"],
    timeout: 30
  )
  
  response = api_client.get(args["endpoint"], args["params"])
  
  {
    data: response.body,
    status: response.status,
    cached_at: Time.now.iso8601
  }
end
```

---

## 🔧 Development Patterns

### Error Handling
```ruby
server.register_tool(name: "robust_operation") do |args|
  begin
    validate_input(args)
    result = perform_operation(args)
    log_success(result)
    result
  rescue ValidationError => e
    log_validation_error(e, args)
    { error: "Invalid input: #{e.message}", code: "VALIDATION_ERROR" }
  rescue ExternalServiceError => e
    log_external_error(e, args)
    { error: "External service failed: #{e.message}", code: "SERVICE_ERROR" }
  rescue StandardError => e
    log_unexpected_error(e, args)
    { error: "Operation failed", code: "INTERNAL_ERROR" }
  end
end
```

### Caching and Performance
```ruby
# Redis-based caching
server.register_tool(name: "cached_operation") do |args|
  cache_key = generate_cache_key(args)
  
  cached_result = redis.get(cache_key)
  return JSON.parse(cached_result) if cached_result
  
  result = expensive_operation(args)
  redis.setex(cache_key, 3600, result.to_json)  # 1 hour TTL
  
  result
end

# Performance monitoring
server.register_tool(name: "monitored_operation") do |args|
  performance_logger = VectorMCP.logger_for("performance")
  
  result = performance_logger.measure("Operation #{args['type']}") do
    perform_operation(args)
  end
  
  # Logs: "Operation data_analysis completed in 2.3s"
  result
end
```

### Background Processing
```ruby
# Queue-based background jobs
server.register_tool(name: "process_async") do |args|
  job_id = SecureRandom.uuid
  
  # Queue background job
  BackgroundWorker.perform_async(
    job_id: job_id,
    operation: args["operation"],
    parameters: args["parameters"]
  )
  
  {
    job_id: job_id,
    status: "queued",
    estimated_completion: Time.now + 300  # 5 minutes
  }
end

server.register_tool(name: "check_job_status") do |args|
  job = BackgroundJob.find(args["job_id"])
  
  {
    job_id: job.id,
    status: job.status,
    progress: job.progress_percentage,
    result: job.completed? ? job.result : nil,
    error: job.failed? ? job.error_message : nil
  }
end
```

---

## 📊 Monitoring and Observability

### Health Checks
```ruby
server.register_tool(name: "health_check") do |args|
  {
    status: "healthy",
    timestamp: Time.now.iso8601,
    version: APP_VERSION,
    uptime: Time.now - START_TIME,
    dependencies: {
      database: check_database_connection,
      redis: check_redis_connection,
      external_api: check_external_api
    }
  }
end
```

### Metrics Collection
```ruby
# Custom metrics for monitoring
metrics_logger = VectorMCP.logger_for("metrics")

server.register_tool(name: "business_operation") do |args|
  start_time = Time.now
  
  begin
    result = perform_business_logic(args)
    
    metrics_logger.info("Operation completed", context: {
      operation: "business_operation",
      duration_ms: ((Time.now - start_time) * 1000).round(2),
      status: "success",
      user_id: session_context&.user&.[](:id)
    })
    
    result
  rescue StandardError => e
    metrics_logger.error("Operation failed", context: {
      operation: "business_operation", 
      duration_ms: ((Time.now - start_time) * 1000).round(2),
      status: "error",
      error: e.class.name
    })
    
    raise
  end
end
```

---

## 🚀 Deployment Strategies

### Docker Container
```dockerfile
FROM ruby:3.2-alpine

WORKDIR /app
COPY Gemfile* ./
RUN bundle install

COPY . .

EXPOSE 8000
CMD ["ruby", "examples/use_cases/production_server.rb"]
```

### Kubernetes Deployment
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vectormcp-server
spec:
  replicas: 3
  selector:
    matchLabels:
      app: vectormcp-server
  template:
    metadata:
      labels:
        app: vectormcp-server
    spec:
      containers:
      - name: vectormcp
        image: vectormcp:latest
        ports:
        - containerPort: 8000
        env:
        - name: JWT_SECRET
          valueFrom:
            secretKeyRef:
              name: vectormcp-secrets
              key: jwt-secret
        - name: LOG_LEVEL
          value: "INFO"
```

### Load Balancer Configuration
```nginx
upstream vectormcp_servers {
    server vectormcp-1:8000;
    server vectormcp-2:8000; 
    server vectormcp-3:8000;
}

server {
    listen 80;
    server_name vectormcp.example.com;
    
    location /mcp/ {
        proxy_pass http://vectormcp_servers;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
    }
}
```

---

## 💡 Best Practices

### Security
- **Always validate inputs** with comprehensive schemas
- **Use authentication** for all production deployments
- **Implement authorization** with principle of least privilege
- **Log security events** for audit trails
- **Sanitize outputs** to prevent data leakage

### Performance
- **Cache expensive operations** with appropriate TTLs
- **Implement timeouts** for external service calls
- **Use background jobs** for long-running operations
- **Monitor performance** with structured logging
- **Scale horizontally** with stateless server design

### Reliability
- **Handle errors gracefully** with proper error types
- **Implement circuit breakers** for external dependencies
- **Use health checks** for monitoring
- **Design for idempotency** where possible
- **Plan for graceful degradation** when services fail

---

## 🚀 Next Steps

Ready to build production applications with VectorMCP?

1. **Choose a use case** that matches your needs
2. **Start with the basic example** to understand the patterns
3. **Add security features** following the core_features examples
4. **Implement monitoring** using the logging examples
5. **Deploy to production** with proper infrastructure

**Need more examples?** Check out:
- **[File System MCP](https://github.com/sergiobayona/file_system_mcp)** - Real-world file operations
- **[Core Features](../core_features/)** - Security and validation patterns

Happy building with VectorMCP! 🚀