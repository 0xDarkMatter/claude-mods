# Security Audit Quick Reference

Essential security patterns for rapid triage during code review and audit.

## Contents

- OWASP Top 10:2025 Quick Reference
- OWASP 2021 to 2025 Crosswalk
- Input Validation
- Output Encoding
- Authentication
- Authorization
- Secrets Management
- Security Headers
- Quick Grep Patterns

## OWASP Top 10:2025 Quick Reference

> Verified 2026-10-05 against https://top10.owasp.org/2025/, the current release. A later
> revision will renumber again - re-check owasp.org before trusting this table.

| ID | Category | Prevention |
|----|----------|------------|
| A01:2025 | Broken Access Control (incl. SSRF, CSRF) | Server-side checks, deny by default, allowlist outbound URLs |
| A02:2025 | Security Misconfiguration | Harden configs, debug off, named CORS origins, cookie flags |
| A03:2025 | Software Supply Chain Failures | Lockfiles, advisory + behavioural scans, SBOM, hardened CI |
| A04:2025 | Cryptographic Failures | TLS, slow password hashes, AEAD modes, keys out of source |
| A05:2025 | Injection (incl. XSS) | Parameterized queries, contextual output encoding |
| A06:2025 | Insecure Design | Threat modeling, abuse cases, quotas on costly flows |
| A07:2025 | Authentication Failures | MFA, rate limiting, no hard-coded credentials, session hygiene |
| A08:2025 | Software or Data Integrity Failures | Verify signatures, SRI, no untrusted deserialization |
| A09:2025 | Security Logging and Alerting Failures | Log security events, alert on them, keep secrets out |
| A10:2025 | Mishandling of Exceptional Conditions | Fail closed, roll back, generic errors, global handler |

Depth: `owasp-top10-a01-a05.md`, `owasp-top10-a06-a10.md`.

## OWASP 2021 to 2025 Crosswalk

Older reports, tickets and scanner output still carry 2021 IDs. Translate by ID through
this table - never compare bare numbers across revisions (A03 was Injection in 2021 and is
Software Supply Chain Failures in 2025). Source: "What's changed" in
https://top10.owasp.org/2025/0x00_2025-Introduction/.

| 2021 | 2021 category | 2025 | Change |
|------|---------------|------|--------|
| A01:2021 | Broken Access Control | A01:2025 | Same; now also holds SSRF |
| A02:2021 | Cryptographic Failures | A04:2025 | Renumbered |
| A03:2021 | Injection | A05:2025 | Renumbered; XSS still here |
| A04:2021 | Insecure Design | A06:2025 | Renumbered |
| A05:2021 | Security Misconfiguration | A02:2025 | Renumbered; XXE still here |
| A06:2021 | Vulnerable and Outdated Components | A03:2025 | Expanded to Software Supply Chain Failures |
| A07:2021 | Identification and Authentication Failures | A07:2025 | Renamed Authentication Failures |
| A08:2021 | Software and Data Integrity Failures | A08:2025 | Renamed Software or Data Integrity Failures |
| A09:2021 | Security Logging and Monitoring Failures | A09:2025 | Renamed Security Logging and Alerting Failures |
| A10:2021 | Server-Side Request Forgery (SSRF) | A01:2025 | Folded into Broken Access Control |
| - | (none) | A10:2025 | New: Mishandling of Exceptional Conditions |

Some CWEs changed category on their own: verbose error messages (CWE-209) sat under
A04:2021 Insecure Design and now belong to A10:2025. When a finding cites a CWE, tag it by
that CWE's 2025 home rather than by translating its old ID.

## Input Validation

```python
# WRONG - Trust user input
def search(query):
    return db.execute(f"SELECT * FROM users WHERE name = '{query}'")

# CORRECT - Parameterized query
def search(query):
    return db.execute("SELECT * FROM users WHERE name = ?", [query])
```

### Validation Rules
```
Always validate:
- Type (string, int, email format)
- Length (min/max bounds)
- Range (numeric bounds)
- Format (regex for patterns)
- Allowlist (known good values)

Never trust:
- URL parameters
- Form data
- HTTP headers
- Cookies
- File uploads
```

## Output Encoding

```javascript
// WRONG - Direct HTML insertion
element.innerHTML = userInput;

// CORRECT - Text content (auto-escapes)
element.textContent = userInput;

// CORRECT - Template with escaping
render(`<div>${escapeHtml(userInput)}</div>`);
```

### Encoding by Context
| Context | Encoding |
|---------|----------|
| HTML body | HTML entity encode |
| HTML attribute | Attribute encode + quote |
| JavaScript | JS encode |
| URL parameter | URL encode |
| CSS | CSS encode |

## Authentication

```python
# Password hashing (use bcrypt, argon2, or scrypt)
import bcrypt

def hash_password(password: str) -> bytes:
    return bcrypt.hashpw(password.encode(), bcrypt.gensalt(rounds=12))

def verify_password(password: str, hashed: bytes) -> bool:
    return bcrypt.checkpw(password.encode(), hashed)
```

### Auth Checklist
- [ ] Hash passwords with bcrypt/argon2 (cost factor 12+)
- [ ] Implement rate limiting on login
- [ ] Use secure session tokens (random, long)
- [ ] Set secure cookie flags (HttpOnly, Secure, SameSite)
- [ ] Implement account lockout after failed attempts
- [ ] Support MFA for sensitive operations

## Authorization

```python
# WRONG - Check only authentication
@login_required
def delete_post(post_id):
    post = Post.get(post_id)
    post.delete()

# CORRECT - Check authorization
@login_required
def delete_post(post_id):
    post = Post.get(post_id)
    if post.author_id != current_user.id and not current_user.is_admin:
        raise Forbidden("Not authorized to delete this post")
    post.delete()
```

## Secrets Management

```python
# WRONG - the secret is a literal in source (and so in git history forever)
client = PaymentClient(key="<live-key-pasted-here>")

# CORRECT - read from the environment at runtime
client = PaymentClient(key=os.environ["PAYMENT_KEY"])

# BETTER - fetch from a secrets manager
client = PaymentClient(key=secrets_client.get_secret("payment-key"))
```

### Secret Handling Rules
```
DO:
- Use environment variables or secrets manager
- Rotate secrets regularly
- Use different secrets per environment
- Audit secret access

DON'T:
- Commit secrets to git
- Log secrets
- Include secrets in error messages
- Share secrets in plain text
```

## Security Headers

```
Content-Security-Policy: default-src 'self'; script-src 'self'
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Strict-Transport-Security: max-age=31536000; includeSubDomains
Referrer-Policy: strict-origin-when-cross-origin
Permissions-Policy: geolocation=(), camera=()
```

## Quick Grep Patterns

```bash
# Find hardcoded secrets
rg -i "(password|secret|api_key|token)\s*=\s*['\"][^'\"]+['\"]" --type py

# Find SQL injection risks
rg "execute\(f['\"]|format\(" --type py

# Find eval/exec usage
rg "\b(eval|exec)\s*\(" --type py

# Check for TODO security items
rg -i "TODO.*security|FIXME.*security"
```
