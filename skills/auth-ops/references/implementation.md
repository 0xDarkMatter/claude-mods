# Implementation Patterns

Practical implementation reference for password hashing, MFA, rate limiting, API keys, and account security flows.

## Password Hashing

### Algorithm Comparison

| Algorithm | Type | Resistance | Recommendation |
|-----------|------|------------|----------------|
| **argon2id** | Memory-hard | GPU, ASIC, side-channel | Best choice for new systems |
| **bcrypt** | CPU-hard | GPU (moderate) | Battle-tested, widely supported |
| **scrypt** | Memory-hard | GPU, ASIC | Good but less library support |
| **PBKDF2** | CPU-hard | GPU (weak) | FIPS compliant, last resort |

### argon2id (Recommended)

OWASP recommended parameters:
- Memory: 19 MiB (19456 KiB)
- Iterations: 2
- Parallelism: 1
- Salt: 16 bytes (random)
- Hash length: 32 bytes

```javascript
// Node.js (argon2 package)
import argon2 from 'argon2';

// Hash a password
async function hashPassword(password) {
  return argon2.hash(password, {
    type: argon2.argon2id,
    memoryCost: 19456,    // 19 MiB
    timeCost: 2,           // 2 iterations
    parallelism: 1,
    saltLength: 16,
    hashLength: 32,
  });
  // Returns: $argon2id$v=19$m=19456,t=2,p=1$salt$hash
}

// Verify a password
async function verifyPassword(hash, password) {
  return argon2.verify(hash, password);
}

// Check if rehash needed (parameters changed)
function needsRehash(hash) {
  return argon2.needsRehash(hash, {
    type: argon2.argon2id,
    memoryCost: 19456,
    timeCost: 2,
    parallelism: 1,
  });
}
```

```python
# Python (argon2-cffi)
from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError

ph = PasswordHasher(
    memory_cost=19456,  # 19 MiB
    time_cost=2,
    parallelism=1,
    hash_len=32,
    salt_len=16,
)

# Hash
hashed = ph.hash("user_password")
# $argon2id$v=19$m=19456,t=2,p=1$salt$hash

# Verify
try:
    ph.verify(hashed, "user_password")
    # Check if rehash needed (parameters updated)
    if ph.check_needs_rehash(hashed):
        new_hash = ph.hash("user_password")
        # Update stored hash
except VerifyMismatchError:
    # Wrong password
    pass
```

```go
// Go (alexedwards/argon2id)
import "github.com/alexedwards/argon2id"

// Hash
hash, err := argon2id.CreateHash("user_password", &argon2id.Params{
    Memory:      19 * 1024, // 19 MiB
    Iterations:  2,
    Parallelism: 1,
    SaltLength:  16,
    KeyLength:   32,
})

// Verify
match, err := argon2id.ComparePasswordAndHash("user_password", hash)
if match {
    // Password is correct
}
```

### bcrypt

Use cost factor 12 or higher (each increment doubles computation time).

```javascript
// Node.js (bcrypt)
import bcrypt from 'bcrypt';

const COST_FACTOR = 12;

// Hash
const hash = await bcrypt.hash(password, COST_FACTOR);

// Verify
const match = await bcrypt.compare(password, hash);
```

```python
# Python (bcrypt)
import bcrypt

# Hash
salt = bcrypt.gensalt(rounds=12)
hashed = bcrypt.hashpw(password.encode(), salt)

# Verify
match = bcrypt.checkpw(password.encode(), hashed)
```

```go
// Go (golang.org/x/crypto/bcrypt)
import "golang.org/x/crypto/bcrypt"

// Hash
hash, err := bcrypt.GenerateFromPassword([]byte(password), 12)

// Verify
err = bcrypt.CompareHashAndPassword(hash, []byte(password))
if err == nil {
    // Password is correct
}
```

**bcrypt limitation:** Input truncated to 72 bytes. For passwords that might exceed this, pre-hash with SHA-256:

```javascript
import crypto from 'crypto';
import bcrypt from 'bcrypt';

function prehashPassword(password) {
  // SHA-256 produces 32 bytes (base64: 44 chars), well under 72
  return crypto.createHash('sha256').update(password).digest('base64');
}

const hash = await bcrypt.hash(prehashPassword(password), 12);
const match = await bcrypt.compare(prehashPassword(password), hash);
```

### Password Rehashing on Login

When upgrading from a weaker algorithm (e.g., bcrypt to argon2id), rehash transparently on successful login:

```javascript
async function login(email, password) {
  const user = await db.findUserByEmail(email);
  if (!user) return null;

  // Verify with current algorithm
  const valid = await verifyPassword(user.passwordHash, password);
  if (!valid) return null;

  // Check if rehash needed (algorithm or parameter upgrade)
  if (needsRehash(user.passwordHash)) {
    const newHash = await hashPassword(password);
    await db.updatePasswordHash(user.id, newHash);
  }

  return user;
}
```

## Rate Limiting Login Attempts

### Sliding Window Implementation

```javascript
// Redis-based rate limiter
import Redis from 'ioredis';
const redis = new Redis(process.env.REDIS_URL);

class LoginRateLimiter {
  constructor(options = {}) {
    this.maxAttempts = options.maxAttempts || 10;
    this.windowMs = options.windowMs || 15 * 60 * 1000; // 15 minutes
    this.lockoutMs = options.lockoutMs || 30 * 60 * 1000; // 30 minutes
  }

  async checkLimit(identifier) {
    // identifier = email or IP address
    const key = `login_attempts:${identifier}`;
    const lockKey = `login_lockout:${identifier}`;

    // Check for lockout
    const locked = await redis.get(lockKey);
    if (locked) {
      const ttl = await redis.ttl(lockKey);
      return {
        allowed: false,
        retryAfter: ttl,
        reason: 'Account temporarily locked',
      };
    }

    // Count recent attempts
    const now = Date.now();
    const windowStart = now - this.windowMs;

    // Remove old entries
    await redis.zremrangebyscore(key, 0, windowStart);

    // Count current attempts
    const attempts = await redis.zcard(key);

    if (attempts >= this.maxAttempts) {
      // Lock the account
      await redis.set(lockKey, '1', 'PX', this.lockoutMs);
      return {
        allowed: false,
        retryAfter: Math.ceil(this.lockoutMs / 1000),
        reason: 'Too many login attempts',
      };
    }

    return {
      allowed: true,
      remaining: this.maxAttempts - attempts - 1,
    };
  }

  async recordAttempt(identifier) {
    const key = `login_attempts:${identifier}`;
    const now = Date.now();
    await redis.zadd(key, now, `${now}`);
    await redis.pexpire(key, this.windowMs);
  }

  async resetAttempts(identifier) {
    // Call on successful login
    await redis.del(`login_attempts:${identifier}`);
    await redis.del(`login_lockout:${identifier}`);
  }
}

// Usage in login endpoint
const limiter = new LoginRateLimiter();

app.post('/auth/login', async (req, res) => {
  const { email, password } = req.body;

  // Rate limit by both email and IP
  const emailCheck = await limiter.checkLimit(email);
  const ipCheck = await limiter.checkLimit(req.ip);

  if (!emailCheck.allowed || !ipCheck.allowed) {
    return res.status(429).json({
      error: 'Too many attempts',
      retryAfter: Math.max(emailCheck.retryAfter || 0, ipCheck.retryAfter || 0),
    });
  }

  const user = await authenticate(email, password);

  if (!user) {
    // Record failed attempt for both identifiers
    await limiter.recordAttempt(email);
    await limiter.recordAttempt(req.ip);

    // IMPORTANT: Use consistent timing to prevent enumeration
    return res.status(401).json({ error: 'Invalid credentials' });
  }

  // Reset on successful login
  await limiter.resetAttempts(email);
  await limiter.resetAttempts(req.ip);

  // Create session/token
  const token = await createAccessToken(user);
  res.json({ token });
});
```

### Progressive Delays

```javascript
// Add artificial delay based on attempt count
async function loginWithDelay(email, password) {
  const attempts = await getRecentAttempts(email);

  // Progressive delay: 0, 0, 0, 1s, 2s, 4s, 8s, 16s (cap at 30s)
  if (attempts > 3) {
    const delay = Math.min(Math.pow(2, attempts - 3) * 1000, 30000);
    await new Promise((resolve) => setTimeout(resolve, delay));
  }

  // IMPORTANT: Apply delay for both success and failure
  // to prevent timing-based enumeration
  return authenticate(email, password);
}
```

## MFA Implementation

### TOTP (Time-Based One-Time Password)

Based on RFC 6238. Uses a shared secret and current time to generate 6-digit codes that change every 30 seconds.

```javascript
// Node.js (otplib)
import { authenticator } from 'otplib';
import QRCode from 'qrcode';

// Step 1: Generate secret for user
function generateTOTPSecret(userEmail, issuer = 'MyApp') {
  const secret = authenticator.generateSecret(); // Base32 encoded

  // Build otpauth:// URI for QR code
  const otpauthUrl = authenticator.keyuri(userEmail, issuer, secret);

  return { secret, otpauthUrl };
}

// Step 2: Generate QR code
async function generateQRCode(otpauthUrl) {
  return QRCode.toDataURL(otpauthUrl);
  // Returns base64 PNG image for display
}

// Step 3: Verify first code (enrollment)
function verifyTOTP(secret, token) {
  // Accept current window +/- 1 (90 second window)
  return authenticator.check(token, secret);
}

// Step 4: Generate backup codes
function generateBackupCodes(count = 10) {
  const codes = [];
  for (let i = 0; i < count; i++) {
    // 8 character alphanumeric codes
    codes.push(crypto.randomBytes(4).toString('hex'));
  }
  return codes;
}

// Step 5: Hash backup codes before storing
async function hashBackupCodes(codes) {
  return Promise.all(
    codes.map(async (code) => ({
      hash: crypto.createHash('sha256').update(code).digest('hex'),
      used: false,
    }))
  );
}
```

```python
# Python (pyotp)
import pyotp
import qrcode
import io
import secrets

def generate_totp_secret(user_email: str, issuer: str = "MyApp"):
    secret = pyotp.random_base32()
    totp = pyotp.TOTP(secret)
    provisioning_uri = totp.provisioning_uri(
        name=user_email,
        issuer_name=issuer,
    )
    return secret, provisioning_uri

def verify_totp(secret: str, token: str) -> bool:
    totp = pyotp.TOTP(secret)
    # valid_window=1 accepts current +/- 1 time step
    return totp.verify(token, valid_window=1)

def generate_backup_codes(count: int = 10) -> list[str]:
    return [secrets.token_hex(4) for _ in range(count)]
```

```go
// Go (pquerna/otp)
import (
    "github.com/pquerna/otp/totp"
)

func GenerateTOTPSecret(email, issuer string) (*otp.Key, error) {
    key, err := totp.Generate(totp.GenerateOpts{
        Issuer:      issuer,
        AccountName: email,
        Period:      30,
        Digits:      otp.DigitsSix,
        Algorithm:   otp.AlgorithmSHA1,
    })
    return key, err
    // key.Secret() - base32 secret
    // key.URL() - otpauth:// URI
}

func VerifyTOTP(secret, token string) bool {
    valid, _ := totp.ValidateCustom(token, secret, time.Now(), totp.ValidateOpts{
        Period:    30,
        Digits:   otp.DigitsSix,
        Algorithm: otp.AlgorithmSHA1,
        Skew:     1, // Accept +/- 1 time step
    })
    return valid
}
```

### TOTP Enrollment Flow

```javascript
// POST /auth/mfa/setup - Start TOTP enrollment
app.post('/auth/mfa/setup', requireAuth, async (req, res) => {
  const user = await getUser(req.auth.sub);

  if (user.mfaEnabled) {
    return res.status(400).json({ error: 'MFA already enabled' });
  }

  const { secret, otpauthUrl } = generateTOTPSecret(user.email);
  const qrCode = await generateQRCode(otpauthUrl);

  // Store secret temporarily (not yet confirmed)
  await db.users.update(req.auth.sub, { pendingMfaSecret: secret });

  res.json({
    qrCode,           // Base64 PNG
    secret,           // Manual entry fallback
    otpauthUrl,       // Direct URL for authenticator
  });
});

// POST /auth/mfa/verify - Confirm enrollment
app.post('/auth/mfa/verify', requireAuth, async (req, res) => {
  const { token } = req.body;
  const user = await getUser(req.auth.sub);

  if (!user.pendingMfaSecret) {
    return res.status(400).json({ error: 'No pending MFA setup' });
  }

  if (!verifyTOTP(user.pendingMfaSecret, token)) {
    return res.status(400).json({ error: 'Invalid code' });
  }

  // Generate backup codes
  const backupCodes = generateBackupCodes(10);
  const hashedCodes = await hashBackupCodes(backupCodes);

  // Activate MFA
  await db.users.update(req.auth.sub, {
    mfaSecret: user.pendingMfaSecret,
    pendingMfaSecret: null,
    mfaEnabled: true,
    backupCodes: hashedCodes,
  });

  // Show backup codes ONCE - user must save them
  res.json({
    success: true,
    backupCodes, // Plaintext, shown only once
    message: 'Save these backup codes in a secure location',
  });
});
```

### WebAuthn / Passkeys

Passkeys provide phishing-resistant authentication using public key cryptography backed by hardware (platform authenticator, security key, or synced passkey).

```javascript
// Server (using @simplewebauthn/server)
import {
  generateRegistrationOptions,
  verifyRegistrationResponse,
  generateAuthenticationOptions,
  verifyAuthenticationResponse,
} from '@simplewebauthn/server';

const rpName = 'My Application';
const rpID = 'example.com';
const origin = 'https://example.com';

// --- Registration (creating a passkey) ---

// Step 1: Generate options
app.post('/auth/passkey/register/options', requireAuth, async (req, res) => {
  const user = await getUser(req.auth.sub);
  const existingCredentials = await db.credentials.findByUser(user.id);

  const options = await generateRegistrationOptions({
    rpName,
    rpID,
    userID: user.id,
    userName: user.email,
    userDisplayName: user.name,
    attestationType: 'none',
    excludeCredentials: existingCredentials.map((c) => ({
      id: c.credentialId,
      type: 'public-key',
    })),
    authenticatorSelection: {
      residentKey: 'preferred',
      userVerification: 'preferred',
    },
  });

  // Store challenge for verification
  await db.challenges.upsert(user.id, options.challenge);

  res.json(options);
});

// Step 2: Verify registration
app.post('/auth/passkey/register/verify', requireAuth, async (req, res) => {
  const user = await getUser(req.auth.sub);
  const challenge = await db.challenges.get(user.id);

  const verification = await verifyRegistrationResponse({
    response: req.body,
    expectedChallenge: challenge,
    expectedOrigin: origin,
    expectedRPID: rpID,
  });

  if (verification.verified && verification.registrationInfo) {
    const { credentialID, credentialPublicKey, counter } =
      verification.registrationInfo;

    await db.credentials.create({
      userId: user.id,
      credentialId: credentialID,
      publicKey: credentialPublicKey,
      counter,
      name: req.body.name || 'My passkey',
      createdAt: new Date(),
    });
  }

  res.json({ verified: verification.verified });
});

// --- Authentication (using a passkey) ---

// Step 1: Generate options
app.post('/auth/passkey/login/options', async (req, res) => {
  const options = await generateAuthenticationOptions({
    rpID,
    userVerification: 'preferred',
    // For discoverable credentials (passkeys), no need to specify allowCredentials
  });

  // Store challenge (keyed by session or response)
  await db.challenges.upsertBySession(req.sessionID, options.challenge);

  res.json(options);
});

// Step 2: Verify authentication
app.post('/auth/passkey/login/verify', async (req, res) => {
  const challenge = await db.challenges.getBySession(req.sessionID);
  const credential = await db.credentials.findByCredentialId(req.body.id);

  if (!credential) {
    return res.status(401).json({ error: 'Unknown credential' });
  }

  const verification = await verifyAuthenticationResponse({
    response: req.body,
    expectedChallenge: challenge,
    expectedOrigin: origin,
    expectedRPID: rpID,
    authenticator: {
      credentialID: credential.credentialId,
      credentialPublicKey: credential.publicKey,
      counter: credential.counter,
    },
  });

  if (verification.verified) {
    // Update counter to prevent replay attacks
    await db.credentials.updateCounter(
      credential.id,
      verification.authenticationInfo.newCounter
    );

    // Create session
    const user = await getUser(credential.userId);
    const token = await createAccessToken(user);
    res.json({ token });
  } else {
    res.status(401).json({ error: 'Verification failed' });
  }
});
```

### Backup Code Verification

```javascript
async function verifyBackupCode(userId, code) {
  const user = await db.users.findOne(userId);
  const codeHash = crypto.createHash('sha256').update(code).digest('hex');

  const matchingCode = user.backupCodes.find(
    (bc) => !bc.used && crypto.timingSafeEqual(
      Buffer.from(bc.hash),
      Buffer.from(codeHash)
    )
  );

  if (!matchingCode) return false;

  // Mark code as used
  matchingCode.used = true;
  matchingCode.usedAt = new Date();
  await db.users.update(userId, { backupCodes: user.backupCodes });

  // Warn if running low
  const remaining = user.backupCodes.filter((bc) => !bc.used).length;
  if (remaining <= 2) {
    await sendEmail(user.email, 'Low backup codes warning',
      `You have ${remaining} backup codes remaining. Consider generating new ones.`
    );
  }

  return true;
}
```

## Secure Password Reset

### Flow

```
1. User requests reset → generate token → send email
2. User clicks link → verify token → show reset form
3. User submits new password → validate token again → update password
4. Invalidate token → invalidate all sessions → notify user
```

### Implementation

```javascript
// Step 1: Request password reset
app.post('/auth/forgot-password', async (req, res) => {
  const { email } = req.body;

  // Rate limit: max 3 reset requests per hour per email
  const rateOk = await checkRateLimit(`reset:${email}`, 3, 3600);
  if (!rateOk) {
    // Still return 200 to prevent enumeration
    return res.json({ message: 'If the email exists, a reset link was sent' });
  }

  const user = await db.findUserByEmail(email);

  if (user) {
    // Generate cryptographically random token
    const token = crypto.randomBytes(32).toString('hex');
    const tokenHash = crypto.createHash('sha256').update(token).digest('hex');

    await db.passwordResets.create({
      userId: user.id,
      tokenHash,
      expiresAt: new Date(Date.now() + 60 * 60 * 1000), // 1 hour
      used: false,
    });

    // Delete any previous unused reset tokens for this user
    await db.passwordResets.deleteUnused(user.id, tokenHash);

    await sendEmail(user.email, 'Password Reset', {
      resetUrl: `https://app.example.com/reset-password?token=${token}`,
      expiresIn: '1 hour',
    });
  }

  // ALWAYS return same response (prevent email enumeration)
  res.json({ message: 'If the email exists, a reset link was sent' });
});

// Step 3: Reset password
app.post('/auth/reset-password', async (req, res) => {
  const { token, newPassword } = req.body;

  // Validate password strength
  if (newPassword.length < 8) {
    return res.status(400).json({ error: 'Password too short (minimum 8)' });
  }

  // Check breached passwords (HaveIBeenPwned API)
  if (await isBreachedPassword(newPassword)) {
    return res.status(400).json({ error: 'This password has been exposed in a data breach' });
  }

  const tokenHash = crypto.createHash('sha256').update(token).digest('hex');
  const resetRecord = await db.passwordResets.findOne({
    tokenHash,
    used: false,
    expiresAt: { $gt: new Date() },
  });

  if (!resetRecord) {
    return res.status(400).json({ error: 'Invalid or expired reset token' });
  }

  // Update password
  const passwordHash = await hashPassword(newPassword);
  await db.users.update(resetRecord.userId, { passwordHash });

  // Mark token as used
  await db.passwordResets.update(resetRecord.id, { used: true, usedAt: new Date() });

  // Invalidate all existing sessions
  await db.sessions.deleteAllForUser(resetRecord.userId);

  // Increment token version to invalidate all JWTs
  await db.users.increment(resetRecord.userId, 'tokenVersion');

  // Send notification email
  const user = await db.users.findOne(resetRecord.userId);
  await sendEmail(user.email, 'Password Changed', {
    message: 'Your password was changed. If you did not do this, contact support immediately.',
  });

  res.json({ message: 'Password reset successfully' });
});
```

### Breached Password Check (HaveIBeenPwned)

```javascript
// k-anonymity: only send first 5 chars of SHA-1 hash
async function isBreachedPassword(password) {
  const sha1 = crypto.createHash('sha1').update(password).digest('hex').toUpperCase();
  const prefix = sha1.substring(0, 5);
  const suffix = sha1.substring(5);

  const response = await fetch(`https://api.pwnedpasswords.com/range/${prefix}`);
  const text = await response.text();

  // Check if our suffix appears in the response
  return text.split('\n').some((line) => {
    const [hashSuffix] = line.split(':');
    return hashSuffix.trim() === suffix;
  });
}
```

## Email Verification

```javascript
// Send verification email on signup
app.post('/auth/register', async (req, res) => {
  const { email, password, name } = req.body;

  const passwordHash = await hashPassword(password);
  const user = await db.users.create({
    email,
    passwordHash,
    name,
    emailVerified: false,
  });

  const token = crypto.randomBytes(32).toString('hex');
  const tokenHash = crypto.createHash('sha256').update(token).digest('hex');

  await db.emailVerifications.create({
    userId: user.id,
    tokenHash,
    expiresAt: new Date(Date.now() + 24 * 60 * 60 * 1000), // 24 hours
  });

  await sendEmail(email, 'Verify your email', {
    verifyUrl: `https://app.example.com/verify-email?token=${token}`,
  });

  res.status(201).json({ message: 'Account created. Check your email to verify.' });
});

// Verify email
app.get('/auth/verify-email', async (req, res) => {
  const { token } = req.query;
  const tokenHash = crypto.createHash('sha256').update(token).digest('hex');

  const record = await db.emailVerifications.findOne({
    tokenHash,
    expiresAt: { $gt: new Date() },
  });

  if (!record) {
    return res.status(400).json({ error: 'Invalid or expired verification link' });
  }

  await db.users.update(record.userId, { emailVerified: true });
  await db.emailVerifications.delete(record.id);

  res.json({ message: 'Email verified successfully' });
});

// Resend verification (rate limited)
app.post('/auth/resend-verification', requireAuth, async (req, res) => {
  const rateOk = await checkRateLimit(`verify:${req.auth.sub}`, 3, 3600);
  if (!rateOk) {
    return res.status(429).json({ error: 'Too many requests. Try again later.' });
  }

  // ... generate new token and send email
  res.json({ message: 'Verification email sent' });
});
```

## Magic Links

Passwordless email authentication using one-time login links.

```javascript
// Request magic link
app.post('/auth/magic-link', async (req, res) => {
  const { email } = req.body;

  // Rate limit
  const rateOk = await checkRateLimit(`magic:${email}`, 5, 3600);
  if (!rateOk) {
    return res.json({ message: 'If the email exists, a login link was sent' });
  }

  const user = await db.findUserByEmail(email);

  if (user) {
    const token = crypto.randomBytes(32).toString('hex');
    const tokenHash = crypto.createHash('sha256').update(token).digest('hex');

    // Invalidate any existing magic link tokens
    await db.magicLinks.deleteForUser(user.id);

    await db.magicLinks.create({
      userId: user.id,
      tokenHash,
      expiresAt: new Date(Date.now() + 10 * 60 * 1000), // 10 minutes
      used: false,
    });

    await sendEmail(email, 'Your login link', {
      loginUrl: `https://app.example.com/auth/magic-link/verify?token=${token}`,
      expiresIn: '10 minutes',
    });
  }

  // Same response regardless of email existence
  res.json({ message: 'If the email exists, a login link was sent' });
});

// Verify magic link
app.get('/auth/magic-link/verify', async (req, res) => {
  const { token } = req.query;
  const tokenHash = crypto.createHash('sha256').update(token).digest('hex');

  const record = await db.magicLinks.findOne({
    tokenHash,
    used: false,
    expiresAt: { $gt: new Date() },
  });

  if (!record) {
    return res.status(400).json({ error: 'Invalid or expired link' });
  }

  // Mark as used (single-use)
  await db.magicLinks.update(record.id, { used: true, usedAt: new Date() });

  // Create session
  const user = await db.users.findOne(record.userId);
  const accessToken = await createAccessToken(user);

  res.json({ token: accessToken });
});
```

## API Key Management

### Key Generation

```javascript
// Generate API key with identifiable prefix
function generateApiKey(prefix = 'sk') {
  // Format: prefix_randompart
  // Example: sk_a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6
  const randomPart = crypto.randomBytes(24).toString('base64url');
  return `${prefix}_${randomPart}`;
}

// Store: hash the key, keep prefix for identification
async function createApiKey(userId, name, permissions, expiresIn) {
  const key = generateApiKey('sk');
  const prefix = key.substring(0, 8); // "sk_a1b2c"
  const keyHash = crypto.createHash('sha256').update(key).digest('hex');

  await db.apiKeys.create({
    userId,
    name,
    prefix,
    keyHash,
    permissions,  // ['read:data', 'write:data']
    expiresAt: expiresIn
      ? new Date(Date.now() + expiresIn)
      : null,
    createdAt: new Date(),
    lastUsedAt: null,
    revoked: false,
  });

  // Return the full key ONCE - it cannot be recovered
  return {
    key, // Show this to the user once
    prefix,
    name,
    permissions,
    expiresAt: expiresIn ? new Date(Date.now() + expiresIn) : null,
  };
}
```

### Key Verification

```javascript
// Verify API key on request
async function verifyApiKey(apiKey) {
  const prefix = apiKey.substring(0, 8);
  const keyHash = crypto.createHash('sha256').update(apiKey).digest('hex');

  const record = await db.apiKeys.findOne({
    prefix,
    revoked: false,
  });

  if (!record) return null;

  // Constant-time comparison
  if (!crypto.timingSafeEqual(
    Buffer.from(keyHash, 'hex'),
    Buffer.from(record.keyHash, 'hex')
  )) {
    return null;
  }

  // Check expiry
  if (record.expiresAt && record.expiresAt < new Date()) {
    return null;
  }

  // Update last used timestamp (async, don't block response)
  db.apiKeys.update(record.id, { lastUsedAt: new Date() }).catch(() => {});

  return record;
}
```

### Key Rotation

```javascript
// Rotate API key (create new, keep old active for grace period)
app.post('/api/keys/:id/rotate', requireAuth, async (req, res) => {
  const oldKey = await db.apiKeys.findOne({ id: req.params.id, userId: req.auth.sub });
  if (!oldKey) return res.status(404).json({ error: 'Key not found' });

  // Create new key with same permissions
  const newKeyResult = await createApiKey(
    req.auth.sub,
    `${oldKey.name} (rotated)`,
    oldKey.permissions,
    oldKey.expiresAt ? oldKey.expiresAt - Date.now() : null
  );

  // Mark old key to expire in 24 hours (grace period)
  await db.apiKeys.update(oldKey.id, {
    expiresAt: new Date(Date.now() + 24 * 60 * 60 * 1000),
    rotatedTo: newKeyResult.prefix,
  });

  res.json({
    newKey: newKeyResult.key, // Show once
    oldKeyExpiresAt: new Date(Date.now() + 24 * 60 * 60 * 1000),
    message: 'Old key will remain active for 24 hours',
  });
});
```

## Session Management

### Concurrent Session Handling

```javascript
// Limit concurrent sessions per user
const MAX_SESSIONS = 5;

async function createSession(userId, metadata) {
  const sessions = await db.sessions.findByUser(userId);

  if (sessions.length >= MAX_SESSIONS) {
    // Remove oldest session
    const oldest = sessions.sort((a, b) => a.createdAt - b.createdAt)[0];
    await db.sessions.delete(oldest.id);
  }

  return db.sessions.create({
    userId,
    createdAt: new Date(),
    lastActiveAt: new Date(),
    expiresAt: new Date(Date.now() + 24 * 60 * 60 * 1000),
    ipAddress: metadata.ip,
    userAgent: metadata.userAgent,
    deviceInfo: parseUserAgent(metadata.userAgent),
  });
}
```

### Session Listing and Revocation

```javascript
// List active sessions
app.get('/auth/sessions', requireAuth, async (req, res) => {
  const sessions = await db.sessions.findByUser(req.auth.sub);

  res.json(sessions.map((s) => ({
    id: s.id,
    current: s.id === req.session.id,
    device: s.deviceInfo,
    ipAddress: s.ipAddress,
    lastActive: s.lastActiveAt,
    createdAt: s.createdAt,
  })));
});

// Revoke a specific session
app.delete('/auth/sessions/:id', requireAuth, async (req, res) => {
  const session = await db.sessions.findOne({
    id: req.params.id,
    userId: req.auth.sub,
  });

  if (!session) return res.status(404).json({ error: 'Session not found' });

  await db.sessions.delete(session.id);
  res.json({ message: 'Session revoked' });
});

// Revoke all sessions except current
app.post('/auth/sessions/revoke-all', requireAuth, async (req, res) => {
  await db.sessions.deleteAllExcept(req.auth.sub, req.session.id);
  res.json({ message: 'All other sessions revoked' });
});
```

## Account Security

### Login Notifications

```javascript
// Notify user of new login from unrecognized device/location
async function checkLoginAnomaly(userId, loginMetadata) {
  const { ip, userAgent, geoLocation } = loginMetadata;
  const knownDevices = await db.knownDevices.findByUser(userId);

  const deviceFingerprint = crypto
    .createHash('sha256')
    .update(`${userAgent}`)
    .digest('hex');

  const isKnown = knownDevices.some((d) => d.fingerprint === deviceFingerprint);

  if (!isKnown) {
    const user = await db.users.findOne(userId);

    // Register new device
    await db.knownDevices.create({
      userId,
      fingerprint: deviceFingerprint,
      userAgent,
      firstSeen: new Date(),
      lastSeen: new Date(),
    });

    // Send notification
    await sendEmail(user.email, 'New login detected', {
      device: parseUserAgent(userAgent),
      location: geoLocation,
      time: new Date().toISOString(),
      message: 'If this was not you, change your password immediately.',
    });
  }
}
```

### Suspicious Activity Detection

```javascript
// Detect and flag suspicious patterns
class SecurityMonitor {
  async checkLogin(userId, metadata) {
    const flags = [];

    // 1. Impossible travel: login from two distant locations in short time
    const lastLogin = await db.loginHistory.findLast(userId);
    if (lastLogin) {
      const distance = geoDistance(lastLogin.location, metadata.location);
      const timeDiff = (Date.now() - lastLogin.timestamp) / 1000 / 3600; // hours
      const maxSpeed = distance / timeDiff; // km/h
      if (maxSpeed > 1000) { // Faster than commercial flight
        flags.push('impossible_travel');
      }
    }

    // 2. Unusual time: login outside user's normal hours
    const loginHour = new Date().getHours();
    const normalHours = await db.users.getNormalLoginHours(userId);
    if (normalHours && (loginHour < normalHours.start || loginHour > normalHours.end)) {
      flags.push('unusual_time');
    }

    // 3. Multiple failed attempts before success
    const recentFailures = await db.loginAttempts.countRecent(userId, 3600, 'failure');
    if (recentFailures >= 5) {
      flags.push('brute_force_attempt');
    }

    // 4. Known bad IP (threat intelligence)
    if (await isKnownBadIP(metadata.ip)) {
      flags.push('suspicious_ip');
    }

    // Log flags and potentially require step-up auth
    if (flags.length > 0) {
      await db.securityEvents.create({
        userId,
        event: 'suspicious_login',
        flags,
        metadata,
        timestamp: new Date(),
      });

      // Require MFA if not already provided
      if (flags.includes('impossible_travel') || flags.includes('suspicious_ip')) {
        return { requireMFA: true, flags };
      }
    }

    return { requireMFA: false, flags };
  }
}
```

## Timing-Safe Operations

Critical for any comparison involving secrets (tokens, passwords, API keys).

```javascript
// WRONG: Standard string comparison leaks timing information
if (providedToken === storedToken) { ... } // VULNERABLE

// CORRECT: Constant-time comparison
import crypto from 'crypto';

function timingSafeCompare(a, b) {
  // Both inputs must be same length for timingSafeEqual
  if (a.length !== b.length) {
    // Still perform comparison to maintain constant time
    crypto.timingSafeEqual(Buffer.from(a), Buffer.from(a));
    return false;
  }
  return crypto.timingSafeEqual(Buffer.from(a), Buffer.from(b));
}
```

```python
# Python
import hmac

# Use hmac.compare_digest for constant-time comparison
if hmac.compare_digest(provided_token, stored_token):
    # Valid
    pass
```

```go
// Go
import "crypto/subtle"

if subtle.ConstantTimeCompare([]byte(provided), []byte(stored)) == 1 {
    // Valid
}
```

## Security Headers for Auth Pages

```javascript
// Helmet.js or manual headers for auth-related pages
app.use((req, res, next) => {
  // Prevent clickjacking
  res.setHeader('X-Frame-Options', 'DENY');
  // Prevent MIME sniffing
  res.setHeader('X-Content-Type-Options', 'nosniff');
  // Enable HSTS
  res.setHeader('Strict-Transport-Security', 'max-age=31536000; includeSubDomains');
  // CSP
  res.setHeader('Content-Security-Policy', "default-src 'self'; script-src 'self'");
  // Prevent referrer leakage (important for reset tokens in URLs)
  res.setHeader('Referrer-Policy', 'no-referrer');
  // Permissions policy
  res.setHeader('Permissions-Policy', 'camera=(), microphone=(), geolocation=()');
  next();
});
```
