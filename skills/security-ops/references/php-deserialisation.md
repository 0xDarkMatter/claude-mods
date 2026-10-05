# PHP Deserialisation

Why `unserialize()` on untrusted data is remote code execution, what PHP 8 changed, and how
Craft's security key fits in. Facts verified 2026-10-05 against php.net/manual and the
OWASP Deserialization Cheat Sheet
(https://cheatsheetseries.owasp.org/cheatsheets/Deserialization_Cheat_Sheet.html).

## Contents

- The Risk
- Safe Alternatives
- If You Must Unserialize
- Phar and Other Hidden Paths
- Signed Data and Craft's Security Key
- Review Checklist

## The Risk

- The PHP manual's warning is unconditional: "Do not pass untrusted user input to
  unserialize() regardless of the options value"
  (https://www.php.net/manual/en/function.unserialize.php).
- `unserialize()` instantiates objects of any loaded class and then runs their magic
  methods (`__wakeup()`, `__unserialize()`, `__destruct()`, `__toString()`). Chained
  together across classes that already sit in `vendor/`, these "gadget chains" reach file
  writes and code execution. Public chains exist for Yii 2, Guzzle, Monolog, Symfony and
  Laravel components (https://github.com/ambionics/phpggc) - all common in a Craft
  `vendor/` tree.
- Untrusted means any byte an attacker can influence: request parameters, cookies you did
  not sign, uploaded files, webhook bodies, third-party API responses, and rows in a
  database or cache that someone else can write.

## Safe Alternatives

OWASP: use "a safe, standard data interchange format such as JSON".

```php
// WRONG
$prefs = unserialize($_COOKIE['prefs']);

// CORRECT - data only, no objects, errors are exceptions
$prefs = json_decode($request->getCookies()->getValue('prefs', '{}'), true, 32, JSON_THROW_ON_ERROR);
if (!is_array($prefs)) {
    $prefs = [];
}
// then validate keys and value types (php-input-validation.md)
```

- `json_decode(..., true)` yields arrays and scalars only - there is no object
  instantiation to abuse. Keep the depth argument small.
- For structured objects, hydrate explicitly from the decoded array
  (`new Prefs(theme: $prefs['theme'] ?? 'light')`) rather than with a generic mapper
  pointed at arbitrary classes.
- `var_export()` + `include` for caches is code generation - only for data you produced.

## If You Must Unserialize

For data your own application wrote and nobody else can modify (a private cache file, a
queue payload you control):

```php
$value = unserialize($payload, [
    'allowed_classes' => false,   // or an explicit list: [Money::class]
    'max_depth'       => 64,      // PHP 7.4+; default 4096
]);
```

- `allowed_classes => false` turns every object into `__PHP_Incomplete_Class`, which
  defuses gadget chains - but the manual's warning applies "regardless of the options
  value", so keep even this form for data you produced.
- PHP 8.4+ throws a `TypeError`/`ValueError` for a malformed `allowed_classes` option
  instead of ignoring it.
- Treat every store that holds serialized PHP (file caches, Redis, database queue tables,
  session storage) as a code-execution boundary: whoever can write to it can likely run
  code. Lock down network access and credentials for Redis and the database accordingly.

## Phar and Other Hidden Paths

- PHP 8.0: "Metadata associated with a phar will no longer be automatically unserialized"
  (https://www.php.net/manual/en/migration80.incompatible.php). The classic
  `file_exists('phar://upload.jpg')` deserialisation trick is closed on PHP 8 - one more
  reason PHP 7.x hosts are urgent upgrades.
- Still never pass user-controlled paths to filesystem functions: stream wrappers
  (`php://filter`, `data://`, `phar://`, remote URLs with `allow_url_fopen`) turn a
  "read a file" call into something else. Allow-list the directory and resolve with
  `realpath()` (`php-input-validation.md`).
- Libraries that unserialize for you count. Laravel's CVE-2018-15133 (a leaked `APP_KEY`
  plus encrypted cookies that were unserialized) is the template for every "signed, then
  unserialized" bug - check what your dependencies do with cookies, sessions and caches.

## Signed Data and Craft's Security Key

An HMAC proves *who produced* a value, not that the value is safe to deserialize. It
moves the risk onto the key:

- Craft's `hashData()`/`validateData()`, `|hash`, `redirectInput()` and cookie validation
  are all keyed by `securityKey` (https://craftcms.com/docs/5.x/reference/config/general.html).
  Current Yii 2 unserializes validated cookies with `allowed_classes => false`
  (yiisoft/yii2 `framework/web/Request.php`), so cookies alone are not a gadget entry
  point - but other signed values are trusted in other ways.
- CVE-2025-23209 is RCE for anyone who already holds a Craft install's security key; it is
  on CISA's Known Exploited Vulnerabilities list
  (https://github.com/craftcms/cms/security/advisories/GHSA-x684-96hh-833x).
  GHSA-5r92-75j8-c534 (September 2026) was RCE through signed-cookie/redirect confusion.
- The lesson for code you write: never `unserialize()` a value because it carried a valid
  signature. Sign JSON, verify with `hash_equals()`, then decode:

```php
[$body, $sig] = explode('.', $token, 2) + [null, null];
$expected = hash_hmac('sha256', (string)$body, $signingKey);
if ($sig === null || !hash_equals($expected, $sig)) {
    throw new \yii\web\BadRequestHttpException();
}
$data = json_decode(base64_decode($body, true) ?: '', true, 16, JSON_THROW_ON_ERROR);
```

- Key handling, generation and rotation: `craft-config-hardening.md`.

## Review Checklist

```bash
rg -n '\bunserialize\s*\(' --type php                         # every hit needs a provenance argument
rg -n 'unserialize\s*\([^)]*\$_(GET|POST|REQUEST|COOKIE)' --type php
rg -n "allowed_classes['\"]?\s*=>\s*true" --type php
rg -n '(file_get_contents|fopen|file_exists|is_file|getimagesize)\s*\([^)]*\$_' --type php
```

- [ ] No `unserialize()` on data an attacker can influence; JSON used instead
- [ ] Remaining `unserialize()` calls pass `allowed_classes` (false or an explicit list)
- [ ] Signed payloads are JSON, verified with `hash_equals()` before decoding
- [ ] Redis, cache and queue stores holding serialized PHP are network-restricted
- [ ] Security key treated as a production credential; PHP 8.x everywhere
