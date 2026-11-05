# PHP 8.x Password Hashing and Tokens

Storing passwords, generating tokens and comparing secrets in PHP 8.x and Craft. Facts
verified 2026-10-05 against php.net/manual and the OWASP Password Storage Cheat Sheet
(https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html).

## Contents

- The PHP Password API
- Choosing Parameters
- Migrating Legacy Hashes
- Tokens and Randomness
- In Craft
- Review Checklist

## The PHP Password API

```php
// Register / change password
$hash = password_hash($password, PASSWORD_DEFAULT);   // store in a VARCHAR(255) column

// Login
if (!password_verify($password, $user->passwordHash)) {
    throw new AuthFailed();                            // same message for unknown user
}
if (password_needs_rehash($user->passwordHash, PASSWORD_DEFAULT)) {
    $user->passwordHash = password_hash($password, PASSWORD_DEFAULT);
    $user->save();
}
```

From https://www.php.net/manual/en/function.password-hash.php and siblings:

- `PASSWORD_DEFAULT` is bcrypt today and is designed to change, which is why the column
  must be 255 wide and why `password_needs_rehash()` exists.
- bcrypt's default cost is 10 up to PHP 8.3 and **12 from PHP 8.4**. Hashes made on 8.3
  report "needs rehash" after an 8.4 upgrade - expected, and harmless if the login path
  rehashes.
- bcrypt **truncates input at 72 bytes** (and at a NUL byte). Two long passphrases that
  share their first 72 bytes verify against each other.
- `password_verify()` embeds algorithm, cost and salt in the hash and is safe against
  timing attacks. The `salt` option has been ignored since PHP 8.0 - never supply one.
- `password_needs_rehash()` belongs only right after a successful `password_verify()`.

## Choosing Parameters

| Algorithm | PHP constant | OWASP minimum | Notes |
|---|---|---|---|
| Argon2id | `PASSWORD_ARGON2ID` (7.3+) | m=19456 KiB, t=2, p=1 | preferred; exists only if PHP was built with Argon2 - check `defined('PASSWORD_ARGON2ID')` |
| bcrypt | `PASSWORD_BCRYPT` / `PASSWORD_DEFAULT` | cost >= 10 | OWASP lists it for legacy systems; use cost 12+ |

```php
$hash = defined('PASSWORD_ARGON2ID')
    ? password_hash($password, PASSWORD_ARGON2ID, ['memory_cost' => 19456, 'time_cost' => 2, 'threads' => 1])
    : password_hash($password, PASSWORD_BCRYPT, ['cost' => 12]);
```

- Benchmark on production hardware: aim for well under a second per hash so login
  cannot be turned into a CPU-exhaustion attack, and rate-limit the login route
  (`auth-account-protection.md`).
- Need passphrases longer than 72 bytes? Prefer Argon2id over pre-hashing tricks; naive
  pre-hashing (an unsalted fast hash before bcrypt) weakens the scheme.
- A pepper, if used, lives outside the database (a secrets manager or HSM), per OWASP.

## Migrating Legacy Hashes

`md5()`, `sha1()`, `hash('sha256', ...)` and `crypt()` with a home-made salt are all
broken for passwords: fast hashes fall to GPU guessing in hours.

1. **Wrap now**: replace every stored legacy hash with `password_hash($legacyHash, ...)`
   and mark the row as wrapped; at login verify with
   `password_verify(md5($password), $stored)`. Every account is protected immediately,
   not only those who log in.
2. **Upgrade on login**: after a successful wrapped verify, store a fresh
   `password_hash($password, ...)` and clear the flag.
3. **Expire stragglers**: after a deadline, force a reset for accounts still wrapped.

## Tokens and Randomness

```php
$token = bin2hex(random_bytes(32));       // 256-bit token, URL-safe hex
$pin   = random_int(100000, 999999);      // CSPRNG integer in a range
$storeThis = hash('sha256', $token);      // keep only the hash of reset/API tokens
// verify:
hash_equals($row->tokenHash, hash('sha256', $presented));
```

- `random_bytes()` is "suitable for all applications, including the generation of
  long-term secrets"; it throws `Random\RandomException` on failure since 8.2
  (https://www.php.net/manual/en/function.random-bytes.php).
- Never use `rand()`, `mt_rand()`, `uniqid()`, `lcg_value()` or `str_shuffle()` for
  anything an attacker must not guess - they are not cryptographically secure.
- Store reset and API tokens hashed, single-use, with an expiry; compare with
  `hash_equals()` (constant time, user-supplied value second).

## In Craft

- Craft hashes user passwords itself; never store passwords in custom fields or plugin
  tables. Plugin code that must hash a secret should use
  `Craft::$app->getSecurity()->hashPassword()` and `validatePassword()` (Yii's bcrypt
  wrapper), or the PHP API above.
- Random strings: `Craft::$app->getSecurity()->generateRandomString(32)`.
- Tamper-evident (not secret) values: `hashData()` / `validateData()`, keyed by the
  security key - readable by the client, so never for confidential data.
- Encryption at rest: `encryptByKey()` / `decryptByKey()`, also keyed by the security key
  - rotating the key makes old ciphertext unreadable (`craft-config-hardening.md`).

## Review Checklist

```bash
rg -n '\b(md5|sha1)\s*\([^)]*(pass|pwd)' -i --type php
rg -n "hash\(\s*['\"](md5|sha1|sha256|sha512)['\"][^)]*pass" -i --type php
rg -n '\b(rand|mt_rand|uniqid|lcg_value|str_shuffle)\s*\(' --type php   # check each use is non-secret
rg -n "password_hash\([^)]*['\"]salt['\"]" --type php
rg -n '(token|secret|signature|hash)\w*\s*(==|!=)[^=]' -i --type php    # should be hash_equals
```

- [ ] Passwords stored with `password_hash()` (Argon2id where available, else bcrypt cost 12+)
- [ ] Login path rehashes with `password_needs_rehash()`
- [ ] No fast hashes for passwords; legacy hashes wrapped and upgraded on login
- [ ] Tokens from `random_bytes()`/`random_int()`, stored hashed, compared with `hash_equals()`
- [ ] Craft-side secrets use Craft's Security service, not hand-rolled crypto
