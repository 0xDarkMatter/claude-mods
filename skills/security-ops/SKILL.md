---
name: security-ops
description: "Security audit orchestrator - parallel dependency, SAST and auth/config agents consolidated into an OWASP-mapped severity report, plus PHP 8, Twig and Craft CMS hardening references. Triggers on: security review, security audit, OWASP, XSS, SQL injection, CSRF, authentication, authorization, secrets management, input validation, vulnerability scan, dependency audit, composer audit, PHP security, Twig escaping, template injection, Craft CMS security, devMode, allowAnonymous, security key, DDEV. Use when auditing or hardening an app before release - e.g. 'security review this PR', 'is this Twig |raw safe?', 'audit our Craft config for production', 'does this controller need allowAnonymous?', 'triage composer audit output', 'diff DDEV against production PHP settings'."
license: MIT
allowed-tools: "Read Edit Write Bash Glob Grep Agent TaskCreate TaskUpdate"
metadata:
  author: claude-mods
  related-skills: auth-ops, testing-ops, debug-ops, monitoring-ops, craftcms-ops, supply-chain-defense, laravel-ops
---

# Security Operations

Orchestrator for security auditing. Detects project stack inline, dispatches three parallel audit agents (dependency, SAST, auth/config review), consolidates into a severity-ranked OWASP-mapped report. Ships one-topic references for PHP 8.x, Twig and Craft CMS 3/4/5.

> Findings use **OWASP Top 10:2025** IDs (https://top10.owasp.org/2025/), as the references do - write them `A05:2025` so every report names its revision. 2025 renumbered the list (Injection A03 -> A05, Misconfiguration A05 -> A02, SSRF folded into A01, new A03 Supply Chain and A10 Exceptional Conditions); translate 2021-tagged reports through the crosswalk in `references/audit-quickref.md`, never by bare number.

## Stack Routing

Load references by what T1 detects. Each is one topic, 300 lines or fewer, opens with a Contents list, and ends with a review checklist of ready-to-run `rg` patterns.

| Detected | Reference | Covers |
|----------|-----------|--------|
| Any web app | `references/owasp-top10-a01-a05.md` | A01-A05:2025: access control + SSRF, misconfig, supply chain, crypto, injection |
| | `references/owasp-top10-a06-a10.md` | A06-A10:2025: design, authn, integrity, logging + alerting, exceptional conditions |
| | `references/audit-quickref.md` | Triage sheet: 2025 table, 2021->2025 crosswalk, validation, secrets, grep patterns |
| | `references/secure-headers.md` | CSP, HSTS, framing, referrer and permissions headers |
| Auth / crypto code | `references/auth-patterns.md` | Password hashing, sessions, JWT, OAuth2 |
| | `references/auth-account-protection.md` | MFA, rate limiting, lockout, password reset |
| | `references/crypto-patterns.md` | AES-GCM, KDFs, signatures, key storage |
| PHP 8.x (`composer.json`) | `references/php-input-validation.md` | Request helpers, filter_var, type juggling, paths, mass assignment |
| | `references/php-sql-queries.md` | Query builder vs raw SQL, identifiers, PDO, element-query params |
| | `references/php-deserialisation.md` | unserialize, JSON, phar, signed data |
| | `references/php-password-hashing.md` | password_hash, Argon2id/bcrypt, legacy hashes, tokens |
| | `references/php-composer-supply-chain.md` | composer audit, advisory blocking, allow-plugins, prod installs |
| Twig | `references/twig-escaping.md` | Autoescape, context strategies, `\|raw`, Craft output helpers |
| | `references/twig-template-injection.md` | SSTI sinks, dynamic includes, Craft's sandbox, Twig floors |
| Craft CMS (`craftcms/cms`) | `references/craft-config-hardening.md` | .env, security key, devMode, production settings |
| | `references/craft-access-control.md` | Permissions, allowAnonymous, require helpers, element auth |
| | `references/craft-csrf-forms.md` | csrfInput, hashed inputs, static caching, Blitz, Formie |
| | `references/craft-uploads-assets.md` | Allowed types, private volumes, transform CVEs |
| | `references/craft-graphql-security.md` | Schemas, tokens, limits, introspection, CORS |
| | `references/craft-advisories.md` | Support windows, exploited CVEs, triage, EOL mitigation |
| DDEV (`.ddev/config.yaml`) | `references/ddev-config-drift.md` | Local vs production PHP/Craft settings, data, `ddev share` |

Craft 3 and Craft 4 are past security end of life (2024-04-30 and 2026-04-30); any audit of one leads with that finding (`craft-advisories.md`).

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
    |       +---> Consolidate: deduplicate, rank by severity, map to OWASP Top 10:2025
    |
    +---> T3: Remediate (dispatch general-purpose + skill preload, foreground + confirm)
            +---> Agent proposes specific fixes
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
| Fix vulnerability in code | T3 | Skill-preloaded agent + confirm |
| Update vulnerable dependency | T3 | Skill-preloaded agent + confirm |
| Add security headers | T3 | Skill-preloaded agent + confirm |

## T1: Detect - Run Inline

| Check | Command / Method |
|-------|-----------------|
| Python project | Check for `requirements.txt`, `pyproject.toml`, `Pipfile` |
| Node.js project | Check for `package.json`, `package-lock.json` |
| Go project | Check for `go.mod` |
| Rust project | Check for `Cargo.toml` |
| Docker | Check for `Dockerfile`, `docker-compose.yml` |
| PHP project | Check for `composer.json`, `composer.lock`; PHP version from `config.platform.php` or `require.php` |
| Craft CMS | `craftcms/cms` in `composer.json`; version via `composer show craftcms/cms` |
| Twig templates | `fd -e twig`, or `.html` files under `templates/` in a Craft project |
| DDEV | Check for `.ddev/config.yaml` (run PHP tools via `ddev composer` / `ddev exec`) |
| composer available | `which composer 2>/dev/null` (`composer audit` needs 2.4+) |
| pip-audit available | `which pip-audit 2>/dev/null` |
| npm audit available | `which npm 2>/dev/null` |
| govulncheck available | `which govulncheck 2>/dev/null` |
| cargo-audit available | `which cargo-audit 2>/dev/null` |
| trivy available | `which trivy 2>/dev/null` |
| Scope: changed files | `git diff --name-only HEAD` |
| Scope: full codebase | `fd -e py -e js -e ts -e go -e rs -e php -e twig` |

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
   - PHP: `composer audit --locked --format=summary` (via `ddev composer` under DDEV).
     Any non-zero exit means findings; never decode the exit bitmask (Composer 2.10+
     returns only 0/1). Read skills/security-ops/references/php-composer-supply-chain.md
   - Craft: also compare `composer show craftcms/cms` against the support windows and
     CVE table in skills/security-ops/references/craft-advisories.md
2. For each vulnerability found, report:
   - Package name and version
   - CVE ID (if available)
   - Severity (Critical/High/Medium/Low)
   - Fixed version (if available)
   - Brief description
   - OWASP category: A03:2025 Software Supply Chain Failures
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
- Read: skills/security-ops/references/owasp-top10-a01-a05.md
- Read: skills/security-ops/references/owasp-top10-a06-a10.md
- If PHP: php-input-validation.md, php-sql-queries.md, php-deserialisation.md (same dir)
- If Twig: twig-escaping.md, twig-template-injection.md (same dir)

## Scope
- Files to scan: {scope from T1 - changed files or full codebase}
- Languages: {languages from T1}

## Scan Categories
For each language detected, search for these patterns using ripgrep:

**Injection (OWASP A05:2025):**
- SQL injection: f-strings/format in execute(), string concatenation in queries
- Command injection: os.system(), subprocess with shell=True, exec(), eval()
- XSS: innerHTML assignment, document.write(), dangerouslySetInnerHTML without sanitization

**SSRF (OWASP A01:2025):**
- HTTP clients (requests, fetch, curl, Guzzle) fed a user-supplied URL with no host allowlist

**Hardcoded Secrets (OWASP A07:2025 credentials, A04:2025 crypto keys):**
- API keys, passwords, tokens assigned as string literals
- .env files tracked in git
- Private keys in source

**Insecure Crypto (OWASP A04:2025):**
- MD5 or SHA1 for passwords (use bcrypt/argon2)
- ECB mode encryption
- Hardcoded encryption keys

**Insecure Deserialization (OWASP A08:2025):**
- pickle.loads on untrusted data (Python)
- JSON.parse without validation
- yaml.load without SafeLoader

**Exceptional Conditions (OWASP A10:2025):**
- Auth/permission checks that return "allowed" from an exception handler (fail open)
- Swallowed or generic catches: `except: pass`, empty `catch {}` blocks
- Unchecked security-relevant returns (PHP `json_decode` without JSON_THROW_ON_ERROR)
- Exception messages or stack traces returned to the client

**PHP / Twig / Craft (if detected):** run the Review Checklist `rg` patterns at the end
of each php-*/twig-* reference - `|raw`, SSTI sinks, interpolated `where()`/`createCommand()`,
request-driven `orderBy`, `unserialize()`, `$allowAnonymous = true`, CSRF opt-outs.

## Instructions
1. Use `rg` (ripgrep) for pattern matching across the codebase
2. Use `ast-grep` for structural patterns if available
3. For each finding, report: file:line, pattern matched, OWASP 2025 ID, severity, fix suggestion
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
- Read: skills/security-ops/references/auth-account-protection.md
- Read: skills/security-ops/references/secure-headers.md
- If Craft: craft-config-hardening.md, craft-access-control.md, craft-csrf-forms.md,
  craft-uploads-assets.md, craft-graphql-security.md (same dir)
- If DDEV: ddev-config-drift.md (same dir)

## Scope
- Files to review: {scope from T1}
- Framework: {detected framework}

## Review Checklist

**Authentication (OWASP A07:2025):**
- Password hashing: bcrypt/argon2 with cost factor 12+?
- Session tokens: cryptographically random, sufficient length?
- Rate limiting on login endpoints?
- Account lockout after failed attempts?
- MFA support for sensitive operations?

**Authorization (OWASP A01:2025):**
- Server-side permission checks on all endpoints?
- Default deny policy?
- IDOR protection (verify ownership before access)?
- Role-based or attribute-based access control?
- CSRF protection on every state-changing request?

**Security Configuration (OWASP A02:2025):**
- CSP header configured?
- HSTS enabled with appropriate max-age?
- X-Frame-Options or frame-ancestors in CSP?
- CORS policy restrictive (not wildcard)?
- Cookie flags: HttpOnly, Secure, SameSite set?
- Debug mode disabled in production config?

**Session Management (OWASP A07:2025):**
- Session timeout configured?
- Session invalidation on logout?
- Session regeneration on privilege change?
- Tokens not exposed in URLs?

**Exceptional Conditions (OWASP A10:2025):**
- Error responses generic - no stack traces, SQL errors or paths leaked?
- Auth, payment and permission paths fail closed when a dependency throws?
- Multi-step writes in a transaction that rolls back as a whole?
- Global exception handler and custom error pages configured?

**Craft CMS / DDEV (if detected):** work through the Review Checklist that ends each
craft-*.md reference and ddev-config-drift.md - devMode, security key, CSRF,
allowAnonymous, GraphQL scope, private uploads, PHP drift.

## Instructions
1. Read auth-related files (login, session, middleware, config)
2. Check each item on the review checklist
3. For each finding: describe the issue, rate severity, cite its OWASP 2025 ID, suggest fix
4. Note items that pass as well as items that fail

IMPORTANT: Do NOT edit any files. This is a read-only review.

## Output Format
Checklist-style report with PASS/FAIL/N-A for each item, findings grouped by category.
```

### Consolidation

After all 3 agents return, consolidate inline:

1. **Deduplicate** - Remove findings that appear in multiple agents (e.g., hardcoded secret found by both Agent 1 and Agent 2)
2. **Rank by severity:**
   - **Critical:** Remote code execution, SQL injection, exposed secrets in production (incl. `unserialize()` of request data, Twig SSTI, a committed Craft security key, a Craft version inside a CISA-KEV-listed range)
   - **High:** XSS, broken auth, missing access control, known CVE with exploit (incl. Craft 3/4 past end of life, `devMode` on in production, `$allowAnonymous = true` on state-changing actions, an authorization check that fails open on exception)
   - **Medium:** Weak crypto, missing security headers, insecure defaults
   - **Low:** Informational, best practice suggestions, TODO items
3. **Map to OWASP Top 10:2025** - Tag each finding `Axx:2025 <Category>` (e.g. `A05:2025 Injection`). When merging with or diffing against an older report, translate its 2021 IDs through the crosswalk in `references/audit-quickref.md` - the same bare number means different categories in the two revisions
4. **Generate report** (see Report Format below)

## T3: Remediate - Skill-Preloaded Dispatch with Confirmation

When user wants to fix findings, dispatch a `general-purpose` agent preloaded with the relevant language `-ops` skill.

**Language routing (same as perf-ops):**

| Finding Type | Dispatch | Preload |
|-------------|----------|---------|
| Python vulnerability | general-purpose | relevant `skills/python-*/SKILL.md` by topic |
| Node.js/JS vulnerability | general-purpose | `skills/javascript-ops/SKILL.md` |
| TypeScript vulnerability | general-purpose | `skills/typescript-ops/SKILL.md` |
| Go vulnerability | general-purpose | `skills/go-ops/SKILL.md` |
| Rust vulnerability | general-purpose | `skills/rust-ops/SKILL.md` |
| SQL injection / DB security | general-purpose | `skills/postgres-ops/SKILL.md` |
| Craft CMS / Twig / PHP | general-purpose | `skills/craftcms-ops/SKILL.md` + the matching `php-`, `twig-` or `craft-` reference here |
| Laravel | general-purpose | `skills/laravel-ops/SKILL.md` |
| Composer / dependency supply chain (A03:2025) | general-purpose | `skills/supply-chain-defense/SKILL.md` |
| General / config / headers | general-purpose | - |

**Dispatch template (T3 preflight):**

```
You are handling a security remediation dispatched by the security-ops orchestrator.

## Domain Knowledge
First, read for context:
- Read: the owasp-top10-*.md half that holds the finding's category (A01-A05 or A06-A10)
- Read: [Preload column for the finding's language]

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
**OWASP revision:** Top 10:2025
**Scan Time:** {duration}

## Summary

| Category | Findings | Critical | High | Medium | Low |
|----------|----------|----------|------|--------|-----|
| Dependencies | X | X | X | X | X |
| Code Patterns | X | X | X | X | X |
| Auth & Config | X | X | X | X | X |

## Critical Findings
{details with file:line, OWASP 2025 ID (e.g. A05:2025), fix suggestion}

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

Reference index: see Stack Routing at the top.

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/dependency-audit.sh` | Multi-language dependency vulnerability scanner (pip-audit, npm, govulncheck, cargo, trivy, composer) |
| `scripts/security-scan.sh` | ripgrep-based code pattern scanner (Python, JS, PHP, Twig, Craft config) |

## See Also

| Skill | When to Combine |
|-------|----------------|
| `auth-ops` | Deep authentication/authorization implementation patterns |
| `craftcms-ops` | Craft content modelling, Twig, element queries, plugins - the "how", where this skill is the "how safely" |
| `supply-chain-defense` | Behavioural dependency scanning, release cooldowns, IOC matching - beyond `composer audit` |
| `laravel-ops` | Laravel-specific remediation |
| `testing-ops` | Security-focused test case generation |
| `monitoring-ops` | Security event logging and alerting |
| `debug-ops` | Investigating security incidents |
