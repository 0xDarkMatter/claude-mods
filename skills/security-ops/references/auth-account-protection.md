# Account Protection Patterns

Controls that protect an account after credentials exist: second factors, throttling, lockout and recovery. Hashing, sessions, JWT and OAuth live in `auth-patterns.md`.

## Contents

- Multi-Factor Authentication
- Rate Limiting
- Account Security

## Multi-Factor Authentication

### TOTP Implementation

```python
import pyotp

def generate_totp_secret() -> str:
    """Generate new TOTP secret for user."""
    return pyotp.random_base32()

def get_totp_uri(secret: str, email: str) -> str:
    """Generate URI for authenticator app."""
    totp = pyotp.TOTP(secret)
    return totp.provisioning_uri(name=email, issuer_name="MyApp")

def verify_totp(secret: str, code: str) -> bool:
    """Verify TOTP code."""
    totp = pyotp.TOTP(secret)
    return totp.verify(code, valid_window=1)  # Allow 30s drift
```

### Backup Codes

```python
def generate_backup_codes(count: int = 10) -> list[str]:
    """Generate one-time backup codes."""
    return [secrets.token_hex(4) for _ in range(count)]

def use_backup_code(user_id: int, code: str) -> bool:
    """Verify and consume backup code."""
    user = get_user(user_id)
    if code in user.backup_codes:
        user.backup_codes.remove(code)
        user.save()
        return True
    return False
```

## Rate Limiting

```python
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address

limiter = Limiter(
    app,
    key_func=get_remote_address,
    default_limits=["200 per day", "50 per hour"]
)

@app.route("/login", methods=["POST"])
@limiter.limit("5 per minute")
def login():
    # Rate limited to 5 attempts per minute per IP
    pass

@app.route("/api/sensitive")
@limiter.limit("10 per minute", key_func=lambda: current_user.id)
def sensitive_endpoint():
    # Rate limited per user, not IP
    pass
```

## Account Security

### Account Lockout

```python
MAX_FAILED_ATTEMPTS = 5
LOCKOUT_DURATION = timedelta(minutes=30)

def record_failed_login(user_id: int) -> None:
    user = get_user(user_id)
    user.failed_login_attempts += 1
    user.last_failed_login = datetime.utcnow()

    if user.failed_login_attempts >= MAX_FAILED_ATTEMPTS:
        user.locked_until = datetime.utcnow() + LOCKOUT_DURATION
        security_logger.warning(f"Account locked: {user.email}")

    user.save()

def check_account_locked(user_id: int) -> bool:
    user = get_user(user_id)
    if user.locked_until and user.locked_until > datetime.utcnow():
        return True
    return False

def reset_failed_attempts(user_id: int) -> None:
    user = get_user(user_id)
    user.failed_login_attempts = 0
    user.locked_until = None
    user.save()
```

### Password Reset

```python
def create_reset_token(user_id: int) -> str:
    """Create password reset token."""
    token = secrets.token_urlsafe(32)
    expires = datetime.utcnow() + timedelta(hours=1)

    # Store hash of token, not token itself
    token_hash = hashlib.sha256(token.encode()).hexdigest()
    store_reset_token(user_id, token_hash, expires)

    return token

def verify_reset_token(token: str) -> int | None:
    """Verify reset token and return user_id."""
    token_hash = hashlib.sha256(token.encode()).hexdigest()
    record = get_reset_token(token_hash)

    if not record or record.expires < datetime.utcnow():
        return None

    # Invalidate token after use
    delete_reset_token(token_hash)
    return record.user_id
```
