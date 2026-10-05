---
name: security-ops
description: "Security audit orchestrator - parallel dependency, SAST and auth/config agents consolidated into an OWASP-mapped severity report, plus PHP 8, Twig and Craft CMS hardening references. Triggers on: security review, security audit, OWASP, XSS, SQL injection, CSRF, authentication, authorization, secrets management, input validation, vulnerability scan, dependency audit, composer audit, PHP security, Twig escaping, template injection, Craft CMS security, devMode, allowAnonymous, security key, DDEV. Use when auditing or hardening an app before release - e.g. 'security review this PR', 'is this Twig |raw safe?', 'audit our Craft config for production', 'does this controller need allowAnonymous?', 'triage composer audit output', 'diff DDEV against production PHP settings'."
license: MIT
allowed-tools: "Read Edit Write Bash Glob Grep Agent TaskCreate TaskUpdate"
metadata:
  author: claude-mods
  related-skills: auth-ops, testing-ops, debug-ops, monitoring-ops, craftcms-ops, ddev-ops, supply-chain-defense, laravel-ops
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
| DDEV (`.ddev/config.yaml`) | `references/ddev-config-drift.md` | Local vs production PHP/Craft settings, data, `ddev share`; DDEV mechanics and a `.ddev/` auditor: `ddev-ops` |

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

Copy each prompt from `references/audit-agent-prompts.md`, filling the `{...}` slots
from T1. What each agent does, so you can route and sanity-check its output:

| Agent | Reads first | Finds | Reports |
|-------|-------------|-------|---------|
| 1 Dependency audit | `scripts/dependency-audit.sh`; PHP: `php-composer-supply-chain.md`, Craft: `craft-advisories.md` | Vulnerable packages via pip-audit, npm audit, govulncheck, cargo audit, trivy, `composer audit --locked` | Severity-ranked table: package, version, CVE, fixed version, `A03:2025` |
| 2 Code pattern scan (SAST) | `scripts/security-scan.sh`, both `owasp-top10-*.md`; PHP/Twig refs when detected | Injection, SSRF, hardcoded secrets, weak crypto, unsafe deserialisation, fail-open exception handling; PHP/Twig checklist `rg` patterns | `file:line`, pattern, OWASP 2025 ID, severity, fix - grouped by category |
| 3 Auth and config review | `auth-patterns.md`, `auth-account-protection.md`, `secure-headers.md`; Craft/DDEV refs when detected | Authn, authz, CSRF, CORS, headers, cookies, sessions, error handling; Craft and DDEV checklists | PASS/FAIL/N-A checklist, findings grouped by category |

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

Dispatch with the T3 preflight prompt in `references/audit-agent-prompts.md`: the agent
proposes changes, security impact, breakage risk, verification and revert first, and
applies nothing until the user confirms.

## Report Format

Write the report from the template in `references/audit-agent-prompts.md` (Report
Format): scope, languages, `OWASP revision: Top 10:2025`, a per-category severity
summary, findings by severity with `file:line` and OWASP 2025 ID, then passed checks.

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
