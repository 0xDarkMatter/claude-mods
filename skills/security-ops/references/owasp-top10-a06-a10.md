# OWASP Top 10:2025 - A06 to A10

In-depth coverage of OWASP Top 10:2025 A06-A10; A01-A05 live in `owasp-top10-a01-a05.md`.
Category list verified 2026-10-05 against https://top10.owasp.org/2025/. The filename names
an ID range, not a revision: tag findings `A10:2025`, and translate 2021-numbered reports
through the crosswalk in `audit-quickref.md`.

## Contents

- A06:2025 - Insecure Design
- A07:2025 - Authentication Failures
- A08:2025 - Software or Data Integrity Failures
- A09:2025 - Security Logging and Alerting Failures
- A10:2025 - Mishandling of Exceptional Conditions
- Review Checklist

## A06:2025 - Insecure Design

### Description
Missing or ineffective security controls from the design phase - no amount of correct
code fixes a flow that was never meant to resist abuse. Down from #4 in 2021.

### Examples
- Business-logic abuse: a coupon redeemable without limit, a price taken from the client
- No limit on a costly flow (SMS sends, exports, AI calls) - abuse becomes a bill
- Tenants separated by a query filter rather than by design
- Recovery questions whose answers are public

### Prevention
- Use threat modeling during design; write abuse cases beside user stories
- Use secure design patterns and paved-road libraries
- Write unit and integration tests for security controls
- Segregate tenants robustly; put quotas on every expensive operation

## A07:2025 - Authentication Failures

### Description
Weaknesses in confirming a user's identity and managing their session. Renamed from
"Identification and Authentication Failures" (A07:2021); still #7.

### Examples
- Permits brute force or credential stuffing (CWE-307)
- Permits weak passwords; weak credential recovery (CWE-640)
- Plain text or weakly hashed passwords
- Hard-coded credentials in source (CWE-798, CWE-259)
- Missing MFA
- Session fixation or IDs that never expire (CWE-384, CWE-613)
- Improper certificate validation on an authenticated channel (CWE-295)

### Prevention

```python
# Rate limiting (flask-limiter 3.x signature)
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address

limiter = Limiter(get_remote_address, app=app)

@app.route("/login", methods=["POST"])
@limiter.limit("5 per minute")
def login():
    ...

# Secure session configuration
app.config.update(
    SESSION_COOKIE_SECURE=True,
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE='Strict',
    PERMANENT_SESSION_LIFETIME=timedelta(hours=1)
)
```

Regenerate the session ID at login and on privilege change. Depth: `auth-patterns.md`,
`auth-account-protection.md`, `php-password-hashing.md`.

## A08:2025 - Software or Data Integrity Failures

### Description
Failure to maintain trust boundaries and verify the integrity of software, code and data
artifacts - at a lower level than A03:2025. Renamed from "Software and Data Integrity
Failures" (A08:2021).

### Examples
- Auto-update or plugin install without signature verification (CWE-494)
- Scripts loaded from a CDN without Subresource Integrity (CWE-829)
- Untrusted deserialization (CWE-502)
- Mass assignment of request fields onto a model (CWE-915)
- Unsigned cookies, JWTs or webhooks trusted as-is (CWE-345)

### Prevention

```python
# WRONG - Pickle from untrusted source
import pickle
data = pickle.loads(user_input)  # RCE vulnerability!

# CORRECT - Use JSON for untrusted data
import json
data = json.loads(user_input)

# Verify signatures
import hmac

def verify_webhook(payload, signature, secret):
    expected = hmac.new(secret, payload, 'sha256').hexdigest()
    return hmac.compare_digest(expected, signature)
```

```html
<!-- SRI pins the exact bytes of a third-party script -->
<script src="https://cdn.example.com/lib.min.js"
        integrity="sha384-<hash-of-the-file>" crossorigin="anonymous"></script>
```

PHP depth: `php-deserialisation.md`; mass assignment in `php-input-validation.md`.

## A09:2025 - Security Logging and Alerting Failures

### Description
Without logging *and alerting*, breaches are not detected or acted on. Renamed from
"Security Logging and Monitoring Failures" (A09:2021) to stress that great logging with no
alerting is of minimal value.

### What to Log
- Login successes and failures
- Access control failures
- Input validation failures
- High-value transactions

### Examples
- Security events not logged, or logged where nobody looks (CWE-778)
- Attacker-controlled text written raw into logs - forged lines (CWE-117)
- Passwords, tokens or session IDs written to logs (CWE-532)

### Prevention

```python
import logging

security_logger = logging.getLogger("security")

def login(username, password):
    user = authenticate(username, password)
    # structured fields, not f-strings: a CRLF in username can't forge a line,
    # and the password never reaches the log
    if user:
        security_logger.info("login_success", extra={"user": username})
        return user
    security_logger.warning("login_failure", extra={"user": username})
    raise AuthenticationError()

# Alert on suspicious patterns - a log line nobody is paged for is not a control
if failed_logins_count > 10:
    security_logger.critical("brute_force_suspected", extra={"ip": ip_address})
    alert_security_team(ip_address)
```

Route alerts to someone on call; `monitoring-ops` owns the alerting pipeline.

## A10:2025 - Mishandling of Exceptional Conditions

### Description
New for 2025 (24 CWEs). Improper error handling, logic errors, failing open and other
results of abnormal conditions. Three failings: the app does not *prevent* the unusual
situation, does not *detect* it as it happens, or *responds* poorly afterwards - leaving
the system in an unknown state.

### Examples
- An authorization check that returns "allowed" from its exception handler (CWE-636)
- Exceptions swallowed or caught generically (CWE-390, CWE-396), or never caught (CWE-248)
- Unchecked return values from security-relevant calls (CWE-252)
- Stack traces, SQL errors or debug data shown to the user (CWE-209, CWE-215)
- A multi-step transaction interrupted half-way and never rolled back
- Resources (locks, handles, temp files) not released on the error path (CWE-460)
- Missing default case or missing-parameter handling (CWE-478, CWE-234)

### Prevention

```python
# WRONG - fails open: any error in the policy engine grants access
def can_edit(user, doc):
    try:
        return policy.check(user, "edit", doc)
    except Exception:
        return True

# CORRECT - fail closed, log, deny
def can_edit(user, doc):
    try:
        return policy.check(user, "edit", doc)
    except PolicyError:
        security_logger.warning("policy_error", extra={"user": user.id, "doc": doc.id})
        return False

# CORRECT - all-or-nothing: any raise rolls back every step
with db.transaction():
    debit(src, amount)
    credit(dst, amount)
    record_transfer(src, dst, amount)

# CORRECT - one global handler: generic message out, detail to the log
@app.errorhandler(Exception)
def on_error(exc):
    if isinstance(exc, HTTPException):  # 404/405 keep their own status
        return exc
    ref = uuid.uuid4().hex[:12]
    app.logger.exception("unhandled", extra={"ref": ref})
    return {"error": "Something went wrong", "ref": ref}, 500
```

```php
// PHP signals many failures by return value, not exception - check them
$data = json_decode($body, true, 512, JSON_THROW_ON_ERROR);  // throws, never null
$raw = file_get_contents($path);
if ($raw === false) {
    throw new RuntimeException('read failed');
}
```

Also: rate limits, quotas and timeouts on everything, so an exceptional condition cannot
become denial of service. Craft's `devMode` is the classic verbose-error leak
(`craft-config-hardening.md`).

## Review Checklist

```bash
# A07 - hard-coded credentials and missing login throttling
rg -n -i "(password|passwd|api_key|token)\s*=\s*['\"][^'\"]+['\"]"
rg -n -i "def login|function login|actionLogin" | rg -v -i "limit"

# A08 - untrusted deserialization, CDN scripts without SRI
rg -n "pickle\.loads?\(|yaml\.load\(|\bunserialize\s*\("
rg -n "<script[^>]+src=[\"']https?://" | rg -v "integrity="

# A09 - f-strings or credentials going into log calls
rg -n "(log|logger)\.\w+\(\s*f['\"]"
rg -n -i "log.*(password|token|secret)"

# A10 - fail-open handlers, swallowed and generic catches, unchecked JSON
rg -n -U "except[^:\n]*:\s*\n\s*(pass|return True)\b" --type py
rg -n "catch\s*\([^)]*\)\s*\{\s*\}"
rg -n "json_decode\(" -g '*.php' | rg -v "JSON_THROW_ON_ERROR"
```
