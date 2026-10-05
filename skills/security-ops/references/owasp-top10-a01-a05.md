# OWASP Top 10 (2021) - A01 to A05

In-depth coverage of OWASP Top 10 (2021) A01-A05; A06-A10 live in `owasp-top10-a06-a10.md`. A newer revision may exist - re-verify the current list at owasp.org.

## Contents

- A01: Broken Access Control
- A02: Cryptographic Failures
- A03: Injection
- A04: Insecure Design
- A05: Security Misconfiguration

## A01: Broken Access Control

### Description
Access control enforces policy such that users cannot act outside their intended permissions.

### Examples
- Bypassing access control by modifying URL, state, or HTML
- Viewing or editing someone else's account
- Privilege escalation (acting as user without login, or user acting as admin)
- Metadata manipulation (replay/tampering JWT, cookies, hidden fields)
- CORS misconfiguration allowing unauthorized API access
- Force browsing to authenticated pages or privileged pages

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

### Checklist
- [ ] Deny by default except for public resources
- [ ] Implement access control once, reuse everywhere
- [ ] Record access control failures, alert on repeated attempts
- [ ] Disable web server directory listing
- [ ] Ensure file metadata not accessible

## A02: Cryptographic Failures

### Description
Failures related to cryptography leading to exposure of sensitive data.

### Examples
- Data transmitted in clear text (HTTP, SMTP, FTP)
- Old/weak cryptographic algorithms (MD5, SHA1, DES)
- Default or weak crypto keys
- Improper certificate validation
- Passwords stored without salted hashing

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
```

### Checklist
- [ ] Classify data by sensitivity
- [ ] Don't store sensitive data unnecessarily
- [ ] Encrypt all sensitive data at rest
- [ ] Use TLS for all data in transit
- [ ] Use strong, standard algorithms
- [ ] Store passwords with bcrypt, scrypt, Argon2, or PBKDF2

## A03: Injection

### Description
Hostile data sent to an interpreter as part of a command or query.

### Examples
- SQL Injection
- NoSQL Injection
- OS Command Injection
- LDAP Injection
- XPath Injection
- Template Injection

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

### Detection Patterns

```bash
# Find SQL injection risks
rg "execute\(f['\"]|format\(|\.format\(" --type py

# Find command injection
rg "os\.system\(|subprocess\.(run|call|Popen)\([^,\[]*\+" --type py
```

## A04: Insecure Design

### Description
Missing or ineffective security controls from design phase.

### Prevention
- Use threat modeling during design
- Integrate security requirements in user stories
- Use secure design patterns
- Write unit and integration tests for security controls
- Segregate tenants robustly

## A05: Security Misconfiguration

### Description
Missing or improper security hardening across the application stack.

### Examples
- Default accounts enabled
- Unnecessary features enabled
- Error messages revealing stack traces
- Missing security headers
- Out of date software

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

