---
name: security-ops
description: "Security audit orchestrator - parallel dependency scanning, SAST pattern detection, auth/config review. Dispatches 3 audit agents simultaneously, consolidates into OWASP-mapped severity report. Triggers on: security review, security audit, OWASP, XSS, SQL injection, CSRF, authentication, authorization, secrets management, input validation, secure coding, vulnerability scan, dependency audit."
license: MIT
allowed-tools: "Read Edit Write Bash Glob Grep Agent TaskCreate TaskUpdate"
metadata:
  author: claude-mods
  related-skills: auth-ops, testing-ops, debug-ops, monitoring-ops
---

# Security Operations

Orchestrator for security auditing. Detects project stack inline, dispatches three parallel audit agents (dependency, SAST, auth/config review), consolidates into a severity-ranked OWASP-mapped report.

## Architecture

```
User requests security audit or mentions security concern
    |
    +---> T1: Detect (inline, fast)
    |       +---> Identify languages/frameworks in project
    |       +---> Check installed audit tools
    |       +---> Determine scope (changed files vs full codebase)
    |       +---> Present: detection summary + recommended audit
    |
    +---> T2: Audit (3 parallel agents, background)
    |       +---> Agent 1: Dependency Audit
    |       |       +---> Run pip-audit, npm audit, govulncheck, cargo audit, trivy
    |       |       +---> Report: CVE IDs, severity, affected + fix versions
    |       |
    |       +---> Agent 2: Code Pattern Scan (SAST)
    |       |       +---> Hardcoded secrets, injection, XSS, eval, shell, weak crypto
    |       |       +---> Report: file:line, pattern, severity, fix suggestion
    |       |
    |       +---> Agent 3: Auth & Config Review
    |       |       +---> Session, CSRF, CORS, CSP, JWT, OAuth, rate limiting, env vars
    |       |       +---> Report: finding, severity, OWASP category, remediation
    |       |
    |       +---> Consolidate: deduplicate, rank by severity, map to OWASP Top 10
    |
    +---> T3: Remediate (dispatch to language expert, foreground + confirm)
            +---> Expert proposes specific fixes
            +---> Preflight: what changes, security impact, risk of breaking
            +---> User confirms
            +---> Apply fixes
```

## Safety Tiers

| Operation | Tier | Execution |
|-----------|------|-----------|
| Detect languages/frameworks | T1 | Inline |
| Check installed audit tools | T1 | Inline |
| Determine scope (changed vs all) | T1 | Inline |
| Dependency vulnerability scan | T2 | Agent 1 (bg) |
| Code pattern scan (SAST) | T2 | Agent 2 (bg) |
| Auth & config review | T2 | Agent 3 (bg) |
| Consolidate findings | T2 | Inline (after agents return) |
| Fix vulnerability in code | T3 | Expert agent + confirm |
| Update vulnerable dependency | T3 | Expert agent + confirm |
| Add security headers | T3 | Expert agent + confirm |

## T1: Detect - Run Inline

| Check | Command / Method |
|-------|-----------------|
| Python project | Check for `requirements.txt`, `pyproject.toml`, `Pipfile` |
| Node.js project | Check for `package.json`, `package-lock.json` |
| Go project | Check for `go.mod` |
| Rust project | Check for `Cargo.toml` |
| Docker | Check for `Dockerfile`, `docker-compose.yml` |
| pip-audit available | `which pip-audit 2>/dev/null` |
| npm audit available | `which npm 2>/dev/null` |
| govulncheck available | `which govulncheck 2>/dev/null` |
| cargo-audit available | `which cargo-audit 2>/dev/null` |
| trivy available | `which trivy 2>/dev/null` |
| Scope: changed files | `git diff --name-only HEAD` |
| Scope: full codebase | `fd -e py -e js -e ts -e go -e rs` |

## T2: Audit - Dispatch 3 Parallel Agents

All audit agents use `model="sonnet"`, `run_in_background=True`. All are **read-only** - instruct them explicitly to never edit files.

### Agent 1: Dependency Audit

```
You are a security dependency auditor. Your job is to find vulnerable dependencies.

## Domain Knowledge
First, read this script for audit commands:
- Read: skills/security-ops/scripts/dependency-audit.sh

## Scope
- Languages detected: {languages from T1}
- Audit tools available: {tools from T1}

## Instructions
1. Run the appropriate audit tool for each detected language:
   - Python: `pip-audit` or `safety check`
   - Node.js: `npm audit --audit-level=moderate`
   - Go: `govulncheck ./...`
   - Rust: `cargo audit`
   - Docker: `trivy config Dockerfile`
2. For each vulnerability found, report:
   - Package name and version
   - CVE ID (if available)
   - Severity (Critical/High/Medium/Low)
   - Fixed version (if available)
   - Brief description
3. If an audit tool is not installed, note which tool is missing and what command installs it

IMPORTANT: Do NOT edit any files. This is a read-only audit.

## Output Format
Report findings as a severity-ranked table.
```

### Agent 2: Code Pattern Scan (SAST)

```
You are a security code scanner. Your job is to find vulnerability patterns in source code.

## Domain Knowledge
First, read these files for scan patterns and OWASP context:
- Read: skills/security-ops/scripts/security-scan.sh
- Read: skills/security-ops/references/owasp-detailed.md

## Scope
- Files to scan: {scope from T1 - changed files or full codebase}
- Languages: {languages from T1}

## Scan Categories
For each language detected, search for these patterns using ripgrep:

**Injection (OWASP A03):**
- SQL injection: f-strings/format in execute(), string concatenation in queries
- Command injection: os.system(), subprocess with shell=True, exec(), eval()
- XSS: innerHTML assignment, document.write(), dangerouslySetInnerHTML without sanitization

**Hardcoded Secrets (OWASP A02):**
- API keys, passwords, tokens assigned as string literals
- .env files tracked in git
- Private keys in source

**Insecure Crypto (OWASP A02):**
- MD5 or SHA1 for passwords (use bcrypt/argon2)
- ECB mode encryption
- Hardcoded encryption keys

**Insecure Deserialization (OWASP A08):**
- pickle.loads on untrusted data (Python)
- JSON.parse without validation
- yaml.load without SafeLoader

## Instructions
1. Use `rg` (ripgrep) for pattern matching across the codebase
2. Use `ast-grep` for structural patterns if available
3. For each finding, report: file:line, pattern matched, OWASP category, severity, fix suggestion
4. Distinguish between confirmed issues and potential false positives

IMPORTANT: Do NOT edit any files. This is a read-only scan.

## Output Format
Group findings by OWASP category, sorted by severity within each group.
```

### Agent 3: Auth & Config Review

```
You are a security reviewer specializing in authentication, authorization, and security configuration.

## Domain Knowledge
First, read these files for auth patterns and header requirements:
- Read: skills/security-ops/references/auth-patterns.md
- Read: skills/security-ops/references/secure-headers.md

## Scope
- Files to review: {scope from T1}
- Framework: {detected framework}

## Review Checklist

**Authentication (OWASP A07):**
- Password hashing: bcrypt/argon2 with cost factor 12+?
- Session tokens: cryptographically random, sufficient length?
- Cookie flags: HttpOnly, Secure, SameSite set?
- Rate limiting on login endpoints?
- Account lockout after failed attempts?
- MFA support for sensitive operations?

**Authorization (OWASP A01):**
- Server-side permission checks on all endpoints?
- Default deny policy?
- IDOR protection (verify ownership before access)?
- Role-based or attribute-based access control?

**Security Configuration (OWASP A05):**
- CSP header configured?
- HSTS enabled with appropriate max-age?
- X-Frame-Options or frame-ancestors in CSP?
- CORS policy restrictive (not wildcard)?
- Debug mode disabled in production config?
- Error messages don't leak internal details?

**Session Management:**
- Session timeout configured?
- Session invalidation on logout?
- Session regeneration on privilege change?
- Tokens not exposed in URLs?

## Instructions
1. Read auth-related files (login, session, middleware, config)
2. Check each item on the review checklist
3. For each finding: describe the issue, rate severity, cite OWASP category, suggest fix
4. Note items that pass as well as items that fail

IMPORTANT: Do NOT edit any files. This is a read-only review.

## Output Format
Checklist-style report with PASS/FAIL/N-A for each item, findings grouped by category.
```

### Consolidation

After all 3 agents return, consolidate inline:

1. **Deduplicate** - Remove findings that appear in multiple agents (e.g., hardcoded secret found by both Agent 1 and Agent 2)
2. **Rank by severity:**
   - **Critical:** Remote code execution, SQL injection, exposed secrets in production
   - **High:** XSS, broken auth, missing access control, known CVE with exploit
   - **Medium:** Weak crypto, missing security headers, insecure defaults
   - **Low:** Informational, best practice suggestions, TODO items
3. **Map to OWASP Top 10** - Tag each finding with its OWASP category
4. **Generate report** (see Report Format below)

## T3: Remediate - Expert Dispatch with Confirmation

When user wants to fix findings, dispatch to the appropriate language expert.

**Language routing (same as perf-ops):**

| Finding Type | Expert Agent |
|-------------|-------------|
| Python vulnerability | python-expert |
| Node.js/JS vulnerability | javascript-expert |
| TypeScript vulnerability | typescript-expert |
| Go vulnerability | go-expert |
| Rust vulnerability | rust-expert |
| SQL injection / DB security | postgres-expert |
| General / config / headers | general-purpose |

**Dispatch template (T3 preflight):**

```
You are handling a security remediation dispatched by the security-ops orchestrator.

## Domain Knowledge
First, read for context:
- Read: skills/security-ops/references/owasp-detailed.md

## Finding to Fix
{specific finding from audit report}

IMPORTANT: Do NOT apply changes yet. Produce a Preflight Report:
1. Exactly what code/config changes you will make
2. Security impact of the fix
3. Risk of breaking existing functionality
4. How to verify the fix works
5. How to revert if the fix causes issues
```

After user confirms, re-dispatch with execute authority.

## Report Format

```markdown
# Security Audit Report

**Scope:** {X files changed | Full codebase}
**Languages:** {detected}
**Scan Time:** {duration}

## Summary

| Category | Findings | Critical | High | Medium | Low |
|----------|----------|----------|------|--------|-----|
| Dependencies | X | X | X | X | X |
| Code Patterns | X | X | X | X | X |
| Auth & Config | X | X | X | X | X |

## Critical Findings
{details with file:line, OWASP mapping, fix suggestion}

## High Findings
{details}

## Medium Findings
{details}

## Low Findings
{details}

## Passed Checks
{items that passed the auth/config review}
```

## Fallback: When Agents Are Unavailable

If agent dispatch fails, fall back to inline scanning:

1. Run `scripts/dependency-audit.sh` directly via Bash
2. Run `scripts/security-scan.sh` directly via Bash
3. Manually check auth patterns using ripgrep
4. Present combined results (less structured than agent-based audit)

## Quick Reference

| Task | Tier | Execution |
|------|------|-----------|
| Detect project stack | T1 | Inline |
| Check audit tools | T1 | Inline |
| Dependency scan | T2 | Agent 1 (bg) |
| Code pattern scan | T2 | Agent 2 (bg) |
| Auth & config review | T2 | Agent 3 (bg) |
| Consolidate report | T2 | Inline |
| Fix vulnerability | T3 | Expert + confirm |
| Update dependency | T3 | Expert + confirm |

## Reference Files

| File | Contents |
|------|----------|
| `references/audit-quickref.md` | OWASP table, input validation, output encoding, auth checklist, secrets rules |
| `references/owasp-detailed.md` | Full OWASP Top 10 with examples and prevention strategies |
| `references/auth-patterns.md` | JWT, OAuth2, session management, bcrypt, argon2, MFA |
| `references/crypto-patterns.md` | AES-GCM, RSA, key management, hashing, digital signatures |
| `references/secure-headers.md` | CSP, HSTS, X-Frame-Options, Referrer-Policy, Permissions-Policy |

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/dependency-audit.sh` | Multi-language dependency vulnerability scanner |
| `scripts/security-scan.sh` | ripgrep-based code pattern security scanner |

## See Also

| Skill | When to Combine |
|-------|----------------|
| `auth-ops` | Deep authentication/authorization implementation patterns |
| `testing-ops` | Security-focused test case generation |
| `monitoring-ops` | Security event logging and alerting |
| `debug-ops` | Investigating security incidents |
