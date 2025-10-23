# SSE Transport Deprecation - GitHub Issue Template

**Use this as a template for creating a GitHub issue to announce the SSE deprecation**

---

## Title
SSE Transport Deprecation Timeline - Removal in v1.0.0

## Labels
- `breaking-change`
- `deprecation`
- `transport`
- `documentation`

## Issue Body

---

# SSE Transport Deprecation Notice

## 📢 Summary

The SSE (Server-Sent Events) transport will be **deprecated in v0.4.0** and **removed in v1.0.0** per MCP specification update (2024-11-05).

**Action Required**: All users currently using `transport: :sse` should migrate to `transport: :http_stream`.

## 📅 Timeline

| Version | Date | Status | Description |
|---------|------|--------|-------------|
| **v0.4.0** | Q1 2025 | Deprecated | SSE functional with runtime warnings |
| **v0.5.0 - v0.9.x** | Q2-Q3 2025 | Maintenance | Security fixes only, no new features |
| **v1.0.0** | Q4 2025 | **Removed** | SSE completely removed from codebase |

**Total Migration Window**: ~9-12 months from v0.4.0 release

## ⚠️ What's Changing

### Deprecated (v0.4.0+)
- ✅ SSE transport remains **fully functional**
- ⚠️ Runtime **deprecation warnings** when using `:sse`
- 📚 Documentation marked as deprecated
- 🔧 Security fixes and critical bugs only

### Removed (v1.0.0+)
- ❌ `VectorMCP::Transport::SSE` class completely removed
- ❌ `:sse` transport symbol no longer accepted
- ❌ All SSE implementation files deleted
- ❌ SSE-specific tests removed
- ❌ SSE examples removed/updated

## 🔄 Migration Path

### Simple Server Migration

**Before (SSE)**:
```ruby
server = VectorMCP.new(name: "MyServer")
server.register_tool(...)
server.run(transport: :sse, port: 8080)
```

**After (HTTP Stream)**:
```ruby
server = VectorMCP.new(name: "MyServer")
server.register_tool(...)  # No changes to registrations!
server.run(transport: :http_stream, port: 8080)
```

### Key Differences

| Aspect | SSE | HTTP Stream |
|--------|-----|-------------|
| **Endpoints** | `GET /mcp/sse`, `POST /mcp/message` | `POST /mcp`, `GET /mcp` |
| **Session ID** | Query parameter `?session_id=X` | Header `Mcp-Session-Id: X` |
| **MCP Spec** | Deprecated 2024-11-05 | Current spec (recommended) |

## 📖 Resources

### Documentation

- **Migration Guide**: [docs/MIGRATION_SSE_TO_HTTP_STREAM.md](../docs/MIGRATION_SSE_TO_HTTP_STREAM.md)
  - Step-by-step migration instructions
  - Client code examples
  - Troubleshooting common issues

- **Examples**: Updated examples demonstrating HTTP Stream
  - [examples/getting_started/basic_http_server.rb](../examples/getting_started/basic_http_server.rb)
  - [examples/getting_started/basic_http_stream_server.rb](../examples/getting_started/basic_http_stream_server.rb)

- **HTTP Stream Documentation**: [CLAUDE.md - HTTP Stream Transport](../CLAUDE.md#http-stream-transport)

### Audit Report

Complete technical analysis available: [docs/SSE_REMOVAL_AUDIT.md](../docs/SSE_REMOVAL_AUDIT.md)

## ❓ Why Remove SSE?

### 1. MCP Specification Alignment

The Model Context Protocol specification (updated 2024-11-05) deprecated SSE transport in favor of streamable HTTP transport. HTTP Stream provides better compatibility with the current MCP standard.

### 2. Simplified Maintenance

- Reduces codebase complexity (~1,156 lines of SSE-specific code)
- Single recommended HTTP transport (instead of two)
- Easier to maintain and improve

### 3. Better User Experience

- Single unified endpoint (`/mcp`) instead of two separate endpoints
- Standard HTTP header-based session management
- Simpler client implementation

## 🚀 What Should You Do?

### If Using SSE Today

1. **Review Migration Guide**: [docs/MIGRATION_SSE_TO_HTTP_STREAM.md](../docs/MIGRATION_SSE_TO_HTTP_STREAM.md)
2. **Plan Migration**: Schedule migration before v1.0.0 release
3. **Update Code**: Change `transport: :sse` to `transport: :http_stream`
4. **Update Clients**: Modify endpoint URLs and session handling
5. **Test Thoroughly**: Verify all functionality works with HTTP Stream
6. **Deploy**: Update production systems before v1.0.0

### If Using Stdio or HTTP Stream

✅ **No action needed!** These transports are not affected.

## 💬 Need Help?

### Getting Support

- **Questions?** Comment on this issue or start a [Discussion](https://github.com/yourusername/vectormcp/discussions)
- **Migration Problems?** Open a new issue with the `migration` label
- **Documentation Issues?** Let us know so we can improve the migration guide

### Providing Feedback

We want to hear from you:

- Are there migration blockers we haven't considered?
- Is the migration guide clear and helpful?
- Do you need more time for migration?
- Any other concerns or suggestions?

**Your feedback helps us ensure a smooth transition for all users.**

## 📋 Checklist for v0.4.0 Release

Preparation work completed:

- [x] SSE codebase audit completed
- [x] Migration guide created and reviewed
- [x] Examples updated to HTTP Stream
- [ ] Deprecation warnings implemented in code
- [ ] CHANGELOG updated
- [ ] README updated with deprecation notice
- [ ] Documentation updated with timeline
- [ ] Community announcement prepared
- [ ] Tests added for deprecation warnings

## 🎯 Next Steps

### For Maintainers

1. **v0.4.0 Preparation**
   - Add deprecation warnings to `server.rb`
   - Update all documentation
   - Release v0.4.0 with deprecation

2. **Maintenance Period (v0.5.0 - v0.9.x)**
   - Monitor migration progress
   - Update migration guide based on user feedback
   - Security fixes only for SSE

3. **v1.0.0 Preparation**
   - Final removal announcement (v0.9.x)
   - Complete SSE removal
   - Release v1.0.0 (major version)

### For Users

1. **Immediate** (Now - v0.4.0 release)
   - Review migration guide
   - Assess impact on your systems
   - Plan migration timeline

2. **Short Term** (v0.4.0 - v0.9.x)
   - Migrate to HTTP Stream
   - Test in staging/development
   - Deploy to production

3. **Before v1.0.0** (Q4 2025)
   - Complete all migrations
   - Verify no SSE usage remains
   - Update to v1.0.0 when released

## 🔗 Related Links

- **MCP Specification**: https://spec.modelcontextprotocol.io/
- **VectorMCP Repository**: https://github.com/yourusername/vectormcp
- **Migration Guide**: [docs/MIGRATION_SSE_TO_HTTP_STREAM.md](../docs/MIGRATION_SSE_TO_HTTP_STREAM.md)
- **Audit Report**: [docs/SSE_REMOVAL_AUDIT.md](../docs/SSE_REMOVAL_AUDIT.md)

---

## Comments Welcome

Please use the comments below to:
- Ask questions about the migration
- Share your migration experiences
- Report issues with the migration guide
- Request clarifications or additional examples
- Provide feedback on the timeline

**Thank you for using VectorMCP!** We're committed to making this transition as smooth as possible.

---

**Issue Author**: @maintainer
**Created**: 2025-XX-XX
**Updated**: 2025-XX-XX
**Status**: Open - Tracking deprecation and removal
