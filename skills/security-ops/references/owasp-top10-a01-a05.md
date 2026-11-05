# OWASP Top 10:2025 - A01 to A05

In-depth coverage of OWASP Top 10:2025 A01-A05; A06-A10 live in `owasp-top10-a06-a10.md`.
Category list verified 2026-10-05 against https://top10.owasp.org/2025/ (the current
release per https://owasp.org/www-project-top-ten/). The filename names an ID range, not a
revision: tag findings `A05:2025`, and translate 2021-numbered reports through the
crosswalk in `audit-quickref.md` - the numbers moved, so a bare "A03" is ambiguous.

## Contents

- A01:2025 - Broken Access Control
- A02:2025 - Security Misconfiguration
- A03:2025 - Software Supply Chain Failures
- A04:2025 - Cryptographic Failures
- A05:2025 - Injection
- Review Checklist

## A01:2025 - Broken Access Control

### Description
Access control enforces policy such that users cannot act outside their intended
permissions. Still #1 in 2025, and now also holds SSRF (A10:2021) and CSRF (CWE-352).

### Examples
- Bypassing access control by modifying URL, state, or HTML
- Viewing or editing someone else's account (IDOR)
- Privilege escalation (acting as user without login, or user acting as admin)
- Metadata manipulation (replay/tampering JWT, cookies, hidden fields)
- CORS misconfiguration allowing unauthorized API access
- Cross-site request forgery on a state-changing endpoint
- Server-side request forgery: the server fetches a URL the user chose

### Prevention

```python
# WRONG - Client-side check only
if user.role == "admin":
    show_admin_button()

# CORRECT - Server-side enforcement
@app.route("/admin/users")
def admin_users():
    if not current_user.has_role("admin"):
        abort(403)
    return render_template("admin/users.html")

# CORRECT - Deny by default
def get_resource(resource_id):
    resource = Resource.get(resource_id)
    if resource.owner_id != current_user.id:
        raise Forbidden("Not your resource")
    return resource
```

### SSRF (folded in from A10:2021)

The server fetches a remote resource from a user-supplied URL, reaching internal
services, cloud metadata (169.254.169.254) or an internal port scan.

```python
# WRONG - Direct URL fetch
def fetch(url):
    return requests.get(url)  # Can fetch internal URLs!

# CORRECT - Allowlist scheme and host, refuse redirects
ALLOWED_HOSTS = {"api.example.com", "cdn.example.com"}

def fetch(url):
    parsed = urlparse(url)
    if parsed.scheme != "https" or parsed.hostname not in ALLOWED_HOSTS:
        raise ValueError("Destination not allowed")
    return requests.get(url, allow_redirects=False, timeout=5)
```

A hostname allowlist beats an IP denylist: denylists miss DNS rebinding, decimal or
IPv6-mapped addresses, and redirects that land on an internal host.

### Checklist
- [ ] Deny by default except for public resources
- [ ] Implement access control once, reuse everywhere
- [ ] Verify ownership on every object lookup, not only at the route
- [ ] CSRF token (or SameSite plus origin check) on every state-changing request
- [ ] Outbound fetches of user-chosen URLs go through a host allowlist
- [ ] Record access control failures, alert on repeated attempts (A09:2025)
- [ ] Disable web server directory listing; keep file metadata unreachable

Craft: `craft-access-control.md`, `craft-csrf-forms.md`.

## A02:2025 - Security Misconfiguration

### Description
Missing or improper security hardening across the application stack. Up from #5 in 2021:
more of an application's behaviour now lives in configuration.

### Examples
- Default accounts enabled, or default credentials unchanged
- Unnecessary features, ports, services or pages enabled
- Debug mode on in production (Django `DEBUG`, Craft `devMode`, Flask debugger)
- Missing security headers; permissive CORS (CWE-942)
- Session cookies without `HttpOnly` / `Secure` (CWE-1004, CWE-614)
- XML parsers that resolve external entities (XXE, CWE-611)
- Passwords in committed configuration files (CWE-260)

Unpatched or unsupported components are A03:2025; a verbose error page is A10:2025.

### Prevention

```yaml
# Secure headers middleware
security_headers:
  Content-Security-Policy: "default-src 'self'"
  X-Frame-Options: "DENY"
  X-Content-Type-Options: "nosniff"
  Strict-Transport-Security: "max-age=31536000"

# Disable debug in production
DEBUG: false
ALLOWED_HOSTS: ["example.com"]
```

```python
# XXE - parse untrusted XML with defusedxml, never the stdlib parsers
from defusedxml.ElementTree import fromstring
doc = fromstring(untrusted_xml)
```

### Checklist
- [ ] A repeatable hardening step builds every environment the same way
- [ ] Debug off and generic error pages in production
- [ ] Headers set (see `secure-headers.md`); CORS names origins, never `*` with credentials
- [ ] Cookie flags: `HttpOnly`, `Secure`, `SameSite`
- [ ] Config secrets come from the environment or a secrets manager

Craft and DDEV: `craft-config-hardening.md`, `ddev-config-drift.md`.

## A03:2025 - Software Supply Chain Failures

### Description
Breakdowns or compromises in building, distributing or updating software - vulnerable or
malicious third-party code, tools or dependencies. New for 2025 as an expansion of
A06:2021 (Vulnerable and Outdated Components): the scope now covers the whole ecosystem of
dependencies, build systems and distribution, not only known CVEs. Fewest occurrences in
OWASP's data, highest average exploit and impact scores.

### Examples
- A dependency with a published advisory (CWE-1395), or unmaintained (CWE-1104)
- A component that cannot be updated (CWE-1329) or comes from an untrusted source (CWE-1357)
- A freshly published malicious version whose install hook steals tokens and republishes
  itself (the 2025 Shai-Hulud npm worm) - no advisory exists yet, so audits pass
- A compromised vendor update (SolarWinds), or one that turns malicious only for one target
- A CI/CD pipeline or IDE extension weaker than the systems it builds and ships
- Floating versions (`^1.2`, `@latest`, `uses: action@v3`) that change under you

### Prevention

```bash
# Known-advisory audit, per ecosystem (the A06:2021 baseline)
uvx pip-audit                       # Python
npm audit --audit-level=moderate    # Node
composer audit --locked             # PHP - see php-composer-supply-chain.md
govulncheck ./...                   # Go
cargo audit                         # Rust
osv-scanner -r .                    # any lockfile, OSV database

# Reproducible installs from the committed lockfile
npm ci
composer install                    # installs exactly composer.lock
uv sync --frozen
```

An advisory audit only sees yesterday's known-bad. Behavioural scanning, a 7-day release
cooldown (Renovate `minimumReleaseAge`, Dependabot `cooldown`), disabled lifecycle scripts,
IOC matching and OIDC publish hygiene are owned by the `supply-chain-defense` skill -
route there rather than repeating them here.

### Checklist
- [ ] Lockfiles committed; CI installs frozen (`npm ci`, `uv sync --frozen`, `composer install`)
- [ ] An SBOM (CycloneDX or SPDX) is generated, including transitive dependencies
- [ ] Advisory audit gates CI; behavioural scan runs on every add or bump
- [ ] Unused dependencies removed; unmaintained ones have a migration plan
- [ ] CI actions pinned to a commit SHA; publish via OIDC, not long-lived tokens
- [ ] No single person can push code to production without a second reviewer
- [ ] Staged or canary rollouts so a poisoned update does not hit every host at once

A03 versus A08: A03 is what you depend on and how it is built and shipped; A08:2025 is
failing to verify integrity at the point of use (unsigned updates, SRI-less CDN scripts,
untrusted deserialization).

## A04:2025 - Cryptographic Failures

### Description
Failures related to cryptography leading to exposure of sensitive data or system
compromise. Down from #2 in 2021.

### Examples
- Data transmitted in clear text (HTTP, SMTP, FTP) (CWE-319)
- Old/weak algorithms (MD5, SHA1, DES, ECB mode) (CWE-327)
- Hard-coded or default crypto keys (CWE-321)
- Weak randomness for tokens, IVs or keys (CWE-330, CWE-338)
- Passwords hashed fast or unsalted (CWE-916)

### Prevention

```python
# WRONG - Weak hashing
import hashlib
password_hash = hashlib.md5(password.encode()).hexdigest()

# CORRECT - bcrypt with cost factor
import bcrypt
password_hash = bcrypt.hashpw(password.encode(), bcrypt.gensalt(rounds=12))

# WRONG - ECB mode
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
cipher = Cipher(algorithms.AES(key), modes.ECB())

# CORRECT - GCM mode with random IV
cipher = Cipher(algorithms.AES(key), modes.GCM(iv))

# WRONG - predictable token
token = str(random.random())

# CORRECT - CSPRNG
token = secrets.token_urlsafe(32)
```

### Checklist
- [ ] Classify data by sensitivity; don't store sensitive data unnecessarily
- [ ] Encrypt all sensitive data at rest; use TLS for all data in transit
- [ ] Use strong, standard algorithms and an AEAD mode
- [ ] Store passwords with Argon2id, scrypt, bcrypt, or PBKDF2
- [ ] Keys come from a KMS or secrets manager, never source

Depth: `crypto-patterns.md`, `php-password-hashing.md`.

## A05:2025 - Injection

### Description
Hostile data sent to an interpreter as part of a command or query. Down from #3 in 2021;
the most-tested category, with the most CVEs. Ranges from XSS (frequent, lower impact) to
SQL injection (rarer, high impact).

### Examples
- SQL and NoSQL injection
- OS command injection
- Cross-site scripting (XSS)
- LDAP and XPath injection
- Server-side template injection

### Prevention

```python
# WRONG - SQL Injection
query = f"SELECT * FROM users WHERE name = '{name}'"

# CORRECT - Parameterized query
cursor.execute("SELECT * FROM users WHERE name = ?", [name])

# WRONG - Command Injection
os.system(f"ping {host}")

# CORRECT - Use subprocess with list
subprocess.run(["ping", "-c", "4", host], capture_output=True)

# WRONG - Template Injection
template = Template(user_input)

# CORRECT - Safe templating
template = env.get_template("page.html")
template.render(user_data=user_input)
```

PHP and Twig depth: `php-sql-queries.md`, `twig-escaping.md`, `twig-template-injection.md`.

## Review Checklist

```bash
# A01 - SSRF: HTTP clients fed a variable URL (confirm no allowlist upstream)
rg -n "requests\.(get|post)\(\s*[a-z_]*url|fetch\(\s*[a-z_]*url|curl_init\(\s*\\\$" -i

# A02 - debug or wildcard CORS left on
rg -n "DEBUG\s*=\s*True|Access-Control-Allow-Origin.*\*|devMode.*true"

# A03 - floating installs and unpinned CI actions (--hidden: .github/ is a dot-dir)
rg -n --hidden "npm install(\s|$)|@latest\b" -g '*.yml' -g '*.yaml' -g 'Dockerfile*'
rg -n "uses:\s*[^@\s]+@" .github/workflows | rg -v "@[0-9a-f]{40}"

# A04 - weak hashes, ECB, non-CSPRNG tokens
rg -n "hashlib\.(md5|sha1)\(|modes\.ECB|random\.random\(\)"

# A05 - SQL, shell and DOM sinks
rg -n "execute\(f['\"]|\.format\(|shell\s*=\s*True|os\.system\(" --type py
rg -n "\.innerHTML\s*=|dangerouslySetInnerHTML|document\.write\(" --type js
```
