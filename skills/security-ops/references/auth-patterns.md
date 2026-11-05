# Authentication Patterns

Secure authentication implementation patterns. MFA, rate limiting, lockout and password reset live in `auth-account-protection.md`.

## Contents

- Password Hashing
- Session Management
- JWT Patterns
- OAuth 2.0 Flow

## Password Hashing

### bcrypt (Recommended)

```python
import bcrypt

def hash_password(password: str) -> bytes:
    """Hash password with bcrypt."""
    salt = bcrypt.gensalt(rounds=12)  # Cost factor 12
    return bcrypt.hashpw(password.encode('utf-8'), salt)

def verify_password(password: str, hashed: bytes) -> bool:
    """Verify password against hash."""
    return bcrypt.checkpw(password.encode('utf-8'), hashed)

# Usage
hashed = hash_password("user_password")
is_valid = verify_password("user_password", hashed)
```

### Argon2 (Modern Alternative)

```python
from argon2 import PasswordHasher

ph = PasswordHasher(
    time_cost=3,      # Iterations
    memory_cost=65536, # 64MB
    parallelism=4,     # Threads
)

def hash_password(password: str) -> str:
    return ph.hash(password)

def verify_password(password: str, hashed: str) -> bool:
    try:
        ph.verify(hashed, password)
        return True
    except:
        return False
```

## Session Management

### Secure Session Configuration

```python
from flask import Flask
from datetime import timedelta

app = Flask(__name__)

app.config.update(
    SECRET_KEY=os.environ['SECRET_KEY'],  # Strong random key
    SESSION_COOKIE_NAME='__session',
    SESSION_COOKIE_SECURE=True,           # HTTPS only
    SESSION_COOKIE_HTTPONLY=True,         # No JavaScript access
    SESSION_COOKIE_SAMESITE='Strict',     # CSRF protection
    PERMANENT_SESSION_LIFETIME=timedelta(hours=1),
)
```

### Session Token Generation

```python
import secrets

def generate_session_id() -> str:
    """Generate cryptographically secure session ID."""
    return secrets.token_urlsafe(32)  # 256 bits of entropy

def generate_csrf_token() -> str:
    """Generate CSRF token."""
    return secrets.token_hex(32)
```

## JWT Patterns

### JWT Generation

```python
import jwt
from datetime import datetime, timedelta

SECRET_KEY = os.environ['JWT_SECRET']
ALGORITHM = "HS256"

def create_token(user_id: int, expires_delta: timedelta = timedelta(hours=1)) -> str:
    expire = datetime.utcnow() + expires_delta
    payload = {
        "sub": str(user_id),
        "exp": expire,
        "iat": datetime.utcnow(),
        "jti": secrets.token_urlsafe(16),  # Unique token ID
    }
    return jwt.encode(payload, SECRET_KEY, algorithm=ALGORITHM)

def verify_token(token: str) -> dict:
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        return payload
    except jwt.ExpiredSignatureError:
        raise AuthError("Token expired")
    except jwt.InvalidTokenError:
        raise AuthError("Invalid token")
```

### JWT Best Practices

```python
# DO
- Use strong secret (256+ bits)
- Set short expiration (15min - 1hr)
- Include jti for revocation
- Use HTTPS only
- Store in httpOnly cookie (not localStorage)

# DON'T
- Store sensitive data in payload (it's base64, not encrypted)
- Use long expiration times
- Send in URL parameters
- Use weak algorithms (none, HS256 with weak key)
```

### Refresh Token Pattern

```python
def create_tokens(user_id: int) -> tuple[str, str]:
    """Create access and refresh token pair."""
    access_token = create_token(
        user_id,
        expires_delta=timedelta(minutes=15),
        token_type="access"
    )
    refresh_token = create_token(
        user_id,
        expires_delta=timedelta(days=7),
        token_type="refresh"
    )
    return access_token, refresh_token

def refresh_access_token(refresh_token: str) -> str:
    """Generate new access token from refresh token."""
    payload = verify_token(refresh_token)

    if payload.get("token_type") != "refresh":
        raise AuthError("Not a refresh token")

    # Check if refresh token is revoked
    if is_token_revoked(payload["jti"]):
        raise AuthError("Token revoked")

    return create_token(payload["sub"], token_type="access")
```

## OAuth 2.0 Flow

### Authorization Code Flow

```python
from authlib.integrations.flask_client import OAuth

oauth = OAuth(app)
oauth.register(
    name='google',
    client_id=os.environ['GOOGLE_CLIENT_ID'],
    client_secret=os.environ['GOOGLE_CLIENT_SECRET'],
    access_token_url='https://oauth2.googleapis.com/token',
    authorize_url='https://accounts.google.com/o/oauth2/auth',
    api_base_url='https://www.googleapis.com/',
    client_kwargs={'scope': 'openid email profile'},
)

@app.route('/login/google')
def google_login():
    redirect_uri = url_for('google_callback', _external=True)
    return oauth.google.authorize_redirect(redirect_uri)

@app.route('/callback/google')
def google_callback():
    token = oauth.google.authorize_access_token()
    user_info = oauth.google.get('oauth2/v3/userinfo').json()

    # Find or create user
    user = find_or_create_user(
        email=user_info['email'],
        name=user_info['name'],
        oauth_provider='google',
        oauth_id=user_info['sub']
    )

    login_user(user)
    return redirect('/')
```
