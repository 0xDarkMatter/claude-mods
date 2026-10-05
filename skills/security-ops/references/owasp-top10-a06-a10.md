# OWASP Top 10 (2021) - A06 to A10

In-depth coverage of OWASP Top 10 (2021) A06-A10; A01-A05 live in `owasp-top10-a01-a05.md`. A newer revision may exist - re-verify the current list at owasp.org.

## Contents

- A06: Vulnerable and Outdated Components
- A07: Identification and Authentication Failures
- A08: Software and Data Integrity Failures
- A09: Security Logging and Monitoring Failures
- A10: Server-Side Request Forgery (SSRF)

## A06: Vulnerable and Outdated Components

### Description
Using components with known vulnerabilities.

### Prevention

```bash
# Python - pip audit
pip install pip-audit
pip-audit

# JavaScript - npm audit
npm audit
npm audit fix

# General - Snyk
snyk test
snyk monitor

# GitHub Dependabot
# .github/dependabot.yml
version: 2
updates:
  - package-ecosystem: "pip"
    directory: "/"
    schedule:
      interval: "weekly"
```

## A07: Identification and Authentication Failures

### Description
Confirmation of user's identity and session management weaknesses.

### Examples
- Permits brute force attacks
- Permits weak passwords
- Weak credential recovery
- Plain text or weakly hashed passwords
- Missing MFA
- Session IDs in URL

### Prevention

```python
# Rate limiting
from flask_limiter import Limiter

limiter = Limiter(app, key_func=get_remote_address)

@app.route("/login", methods=["POST"])
@limiter.limit("5 per minute")
def login():
    # Login logic

# Secure session configuration
app.config.update(
    SESSION_COOKIE_SECURE=True,
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE='Strict',
    PERMANENT_SESSION_LIFETIME=timedelta(hours=1)
)
```

## A08: Software and Data Integrity Failures

### Description
Code and infrastructure without integrity verification.

### Examples
- Insecure CI/CD pipeline
- Auto-update without verification
- Untrusted deserialization

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

## A09: Security Logging and Monitoring Failures

### Description
Without logging and monitoring, breaches cannot be detected.

### What to Log
- Login successes and failures
- Access control failures
- Input validation failures
- High-value transactions

### Prevention

```python
import logging

security_logger = logging.getLogger("security")

def login(username, password):
    user = authenticate(username, password)
    if user:
        security_logger.info(f"Login success: {username}")
        return user
    else:
        security_logger.warning(f"Login failed: {username}")
        raise AuthenticationError()

# Alert on suspicious patterns
if failed_logins_count > 10:
    security_logger.critical(f"Brute force detected: {ip_address}")
    alert_security_team(ip_address)
```

## A10: Server-Side Request Forgery (SSRF)

### Description
Application fetches remote resource without validating user-supplied URL.

### Examples
- Accessing internal services
- Reading cloud metadata
- Port scanning internal network

### Prevention

```python
# WRONG - Direct URL fetch
import requests

def fetch(url):
    return requests.get(url)  # Can fetch internal URLs!

# CORRECT - Validate URL
from urllib.parse import urlparse

ALLOWED_HOSTS = {"api.example.com", "cdn.example.com"}

def fetch(url):
    parsed = urlparse(url)
    if parsed.hostname not in ALLOWED_HOSTS:
        raise ValueError("Host not allowed")
    if parsed.scheme not in ("http", "https"):
        raise ValueError("Scheme not allowed")
    return requests.get(url)
```
