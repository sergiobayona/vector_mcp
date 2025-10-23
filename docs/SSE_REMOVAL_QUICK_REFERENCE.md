# SSE Transport Removal - Quick Reference

**Quick reference guide for maintainers implementing the SSE removal plan**

---

## 📅 Timeline At-a-Glance

| Version | Quarter | Status | Key Actions |
|---------|---------|--------|-------------|
| v0.4.0 | Q1 2025 | Deprecation | Add warnings, update docs |
| v0.5.0-0.9.x | Q2-Q3 2025 | Maintenance | Security fixes only |
| v1.0.0 | Q4 2025 | Removal | Delete SSE code |

---

## 📂 Files to Eventually Remove (v1.0.0)

### Source Files (lib/)
```bash
rm lib/vector_mcp/transport/sse.rb
rm lib/vector_mcp/transport/sse_session_manager.rb
rm -rf lib/vector_mcp/transport/sse/
```

### Test Files (spec/)
```bash
rm spec/vector_mcp/transport/sse_spec.rb
rm spec/vector_mcp/transport/sse_context_integration_spec.rb
rm spec/vector_mcp/transport/sse_security_fix_spec.rb
rm spec/integration/sse_basic_integration_spec.rb
rm -rf spec/vector_mcp/transport/sse/
```

**Total**: ~1,156 lines of code

---

## 🔧 Quick Code Changes

### For v0.4.0 (Deprecation)

**Add warning to `lib/vector_mcp/server.rb` (around line 151)**:
```ruby
when :sse
  warn "\n" + "=" * 80
  warn "DEPRECATION WARNING: SSE Transport"
  warn "=" * 80
  warn "SSE transport is deprecated and will be removed in v1.0.0 (Q4 2025)"
  warn "Action Required: Migrate to :http_stream transport"
  warn "Migration Guide: https://github.com/.../docs/MIGRATION_SSE_TO_HTTP_STREAM.md"
  warn "=" * 80 + "\n"

  require_relative "transport/sse"
  VectorMCP::Transport::SSE.new(self, **options)
```

### For v1.0.0 (Removal)

**Replace SSE case in `lib/vector_mcp/server.rb`**:
```ruby
when :sse
  raise ArgumentError,
    "SSE transport was removed in VectorMCP v1.0.0 (per MCP spec 2024-11-05). " \
    "Please use :http_stream transport instead. " \
    "Migration guide: https://github.com/.../docs/MIGRATION_SSE_TO_HTTP_STREAM.md"
```

---

## 📝 Documentation Updates

### v0.4.0 Checklist
- [ ] Add deprecation warning to server.rb
- [ ] Add deprecation comments to all SSE files
- [ ] Update CLAUDE.md with deprecation notice
- [ ] Update CHANGELOG with deprecation entry
- [ ] Create GitHub issue from `docs/SSE_DEPRECATION_ANNOUNCEMENT.md`
- [ ] Add test for deprecation warning

### v1.0.0 Checklist
- [ ] Remove all SSE source files
- [ ] Remove all SSE test files
- [ ] Update server.rb (replace SSE case with error)
- [ ] Update CLAUDE.md (remove SSE sections)
- [ ] Update CHANGELOG (document removal)
- [ ] Run full test suite
- [ ] Update version to 1.0.0

---

## 🧪 Testing Commands

### Verify Deprecation Warning (v0.4.0+)
```bash
# Should show deprecation warning
ruby -e "require 'vector_mcp'; VectorMCP.new(name: 't').run(transport: :sse)"
```

### Verify Removal (v1.0.0+)
```bash
# Should raise ArgumentError
ruby -e "require 'vector_mcp'; VectorMCP.new(name: 't').run(transport: :sse)"
# Expected: ArgumentError with migration guide link
```

### Run Test Suite
```bash
bundle exec rspec
# Should pass without SSE tests after removal
```

---

## 📖 User Communication

### When Users Ask About SSE

**Response Template**:
```
SSE transport was deprecated in v0.4.0 and will be removed in v1.0.0 (Q4 2025).

Please migrate to HTTP Stream transport:
- Change `transport: :sse` to `transport: :http_stream`
- See migration guide: docs/MIGRATION_SSE_TO_HTTP_STREAM.md

For questions or issues, please open a GitHub issue with the 'migration' label.
```

---

## ⚠️ Important Notes

### Dependencies
**DO NOT remove** `falcon` or `async` gems - they are used by HttpStream transport!

```bash
# Verify before removing dependencies:
grep -r "falcon" lib/ --exclude-dir=sse
grep -r "async" lib/ --exclude-dir=sse
# Both should show HttpStream usage
```

### Examples
Both example files already updated to use HttpStream:
- ✅ `examples/getting_started/basic_http_server.rb`
- ✅ `examples/getting_started/minimal_server.rb`

### Migration Guide
Comprehensive guide available at: `docs/MIGRATION_SSE_TO_HTTP_STREAM.md`

---

## 🔗 Quick Links

| Document | Purpose |
|----------|---------|
| [MIGRATION_SSE_TO_HTTP_STREAM.md](MIGRATION_SSE_TO_HTTP_STREAM.md) | User migration guide |
| [SSE_REMOVAL_AUDIT.md](SSE_REMOVAL_AUDIT.md) | Technical audit report |
| [SSE_DEPRECATION_ANNOUNCEMENT.md](SSE_DEPRECATION_ANNOUNCEMENT.md) | GitHub issue template |
| [PHASE1_COMPLETION_SUMMARY.md](PHASE1_COMPLETION_SUMMARY.md) | Phase 1 status |
| [ANALYSIS_SUMMARY.md](../ANALYSIS_SUMMARY.md) | Original code analysis |

---

## 🎯 Success Metrics

### v0.4.0 Success
- [ ] All users see deprecation warning
- [ ] No functionality broken
- [ ] Migration guide is helpful (no major issues reported)

### v1.0.0 Success
- [ ] SSE code completely removed
- [ ] All tests pass without SSE
- [ ] Clear error message guides users
- [ ] <5% of users report migration problems

---

**Last Updated**: 2025-10-23
**Maintained By**: VectorMCP Core Team
