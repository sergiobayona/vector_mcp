# 🎯 VectorMCP Examples

Welcome to the VectorMCP examples! This directory contains comprehensive demonstrations of the VectorMCP framework, organized by learning path and use case.

VectorMCP is a Ruby implementation of the [Model Context Protocol (MCP)](https://modelcontext.dev/), enabling you to create servers that expose tools, resources, prompts, and filesystem roots to LLM clients.

## 🗺️ Choose Your Path

### 🚀 New to VectorMCP?
**Start here** → [`getting_started/`](./getting_started/) 

Perfect for first-time users who want to understand the basics and get running quickly.

### 🔧 Exploring Features?
**Deep dive** → [`core_features/`](./core_features/)

Comprehensive examples of VectorMCP's key capabilities like authentication, validation, and filesystem operations.

### 📊 Need Logging?
**Observability** → [`logging/`](./logging/)

Production-ready logging patterns, structured output, and monitoring integration.

### 🎯 Real-World Use Cases?
**Production patterns** → [`use_cases/`](./use_cases/)

Practical implementations for common scenarios like file operations and data processing.

---

## 📁 Directory Structure

```
examples/
├── 🚀 getting_started/          # Start here for new users
│   ├── minimal_server.rb        # Simplest possible MCP server
│   └── basic_http_server.rb     # Web-based integration
│
├── 🔧 core_features/            # VectorMCP capabilities
│   ├── input_validation.rb      # Schema and runtime validation
│   ├── filesystem_roots.rb      # Secure file operations
│   ├── authentication.rb        # API keys, JWT, custom auth
│   └── cli_client.rb           # MCP client implementation
│
├── 📊 logging/                  # Observability and monitoring
│   ├── basic_logging.rb         # Component-based logging
│   ├── structured_logging.rb    # JSON output and context
│   ├── security_logging.rb      # Audit trails and events
│   └── log_analysis.rb         # Log processing tools
│
└── 🎯 use_cases/                # Real-world implementations
    ├── file_operations.rb       # File system automation
    ├── data_analysis.rb         # Data processing workflows
    └── web_scraping.rb          # Content extraction patterns
```

---

## ⚡ Quick Start

### 1. Install Dependencies
```bash
cd VectorMCP/
bundle install
```

### 2. Run Your First Server
```bash
# Minimal example (5 lines of code)
ruby examples/getting_started/minimal_server.rb

# Or web-based integration  
ruby examples/getting_started/basic_http_server.rb
```

### 3. Connect a Client
```bash
# In another terminal
ruby examples/core_features/cli_client.rb http://localhost:8080/sse
```

---

## 🔗 Transport Options

| Transport | Best For | Example |
|-----------|----------|---------|
| **HTTP Stream** | Web apps, browsers, dashboards, CLI tools | `basic_http_stream_server.rb` |
| **HTTP/SSE** | Legacy web integrations (deprecated) | `basic_http_server.rb` |

---

## 🛡️ Security Features

All examples demonstrate VectorMCP's security-first approach:

- **Input Validation**: Schema-based parameter validation
- **Authentication**: API keys, JWT tokens, custom strategies  
- **Authorization**: Role-based access control
- **Audit Logging**: Comprehensive security event tracking
- **Filesystem Boundaries**: Secure root definitions

---

## 📖 Learning Path Recommendations

### Beginner Journey
1. **Start**: `getting_started/minimal_server.rb`
2. **Expand**: `getting_started/basic_http_server.rb`
3. **Secure**: `core_features/authentication.rb`
4. **Validate**: `core_features/input_validation.rb`

### Advanced Journey  
1. **Production Logging**: `logging/structured_logging.rb`
2. **Real Applications**: `use_cases/file_operations.rb`

### Security-Focused Journey
1. **Authentication**: `core_features/authentication.rb`
2. **File Security**: `core_features/filesystem_roots.rb`
3. **Audit Logging**: `logging/security_logging.rb`

---

## 🔧 Development Commands

```bash
# Run any example
ruby examples/path/to/example.rb

# With debug output
DEBUG=1 ruby examples/path/to/example.rb

# Test logging output
ruby examples/logging/structured_logging.rb | jq .
```

---

## 🌟 Featured Examples

### 🎯 Most Popular
- **`getting_started/minimal_server.rb`** - Learn MCP basics in 5 minutes
- **`core_features/authentication.rb`** - Production security patterns
- **`logging/structured_logging.rb`** - Production observability

### 🔥 Advanced Use Cases
- **`logging/security_logging.rb`** - Audit trail implementation
- **`use_cases/file_operations.rb`** - Secure file system operations

---

## 📚 Additional Resources

- **[Main Documentation](../README.md)** - Full API reference
- **[Security Guide](../security/README.md)** - Authentication and authorization
- **[MCP Specification](https://modelcontext.dev/)** - Protocol details
- **[CLAUDE.md](../CLAUDE.md)** - Development guidelines

---

## 🤝 Contributing Examples

When adding new examples:

1. **Choose the right category** based on primary purpose
2. **Follow naming conventions** (`feature_name.rb`)
3. **Include comprehensive comments** explaining the what and why
4. **Add input validation** for security
5. **Update relevant README files**

---

## 💡 Need Help?

- **Getting Started Issues**: Check `getting_started/README.md`
- **Feature Questions**: Browse `core_features/README.md`  
- **Production Deployment**: Review `use_cases/README.md`

Happy coding with VectorMCP! 🚀