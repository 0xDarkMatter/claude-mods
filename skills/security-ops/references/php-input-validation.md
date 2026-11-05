# PHP 8.x Input Validation

Validating request data in PHP 8.x, with the Craft/Yii request helpers where they apply.
Facts verified 2026-10-05 against php.net/manual and the OWASP Input Validation Cheat
Sheet (https://cheatsheetseries.owasp.org/cheatsheets/Input_Validation_Cheat_Sheet.html).

## Contents

- Principles
- Reading Request Data in Craft
- Validating Scalars
- Type Juggling
- Files, Paths and Commands
- Mass Assignment
- Review Checklist

## Principles

- **Allow-list, server-side.** OWASP: define what the application accepts and reject
  everything else. Client-side checks are UX, not security.
- **Validate at the boundary, encode at the output.** Validation decides whether input is
  acceptable; escaping (`twig-escaping.md`) and parameter binding (`php-sql-queries.md`)
  make it safe in each sink. One never replaces the other.
- **Validate type and shape before value.** PHP request arrays can hold arrays where you
  expect strings (`?id[]=1`), and that is where many bypasses start.
- **Fail closed.** A value that fails validation is rejected, not "cleaned" into
  something plausible.

## Reading Request Data in Craft

Prefer the Craft/Yii request API to superglobals - it is testable and makes intent explicit:

| Call | Behaviour |
|---|---|
| `$this->request->getRequiredBodyParam('x')` | 400 if missing |
| `$this->request->getBodyParam('x', $default)` | POST body value or default |
| `$this->request->getQueryParam('x')` | query-string value |
| `$this->request->getValidatedBodyParam('x')` | value must carry a valid `\|hash` HMAC, else 400 (`craft-csrf-forms.md`) |

Any of these can return an array. Check the type before using the value:

```php
$email = $this->request->getRequiredBodyParam('email');
if (!is_string($email) || filter_var($email, FILTER_VALIDATE_EMAIL) === false) {
    throw new \yii\web\BadRequestHttpException('Invalid email');
}
```

In Twig, `craft.app.request.getParam()` and friends return the same untrusted values -
do not pass them straight into element-query parameters, template names or `|raw`.

## Validating Scalars

`filter_var()` returns `false` on failure, or `null` with `FILTER_NULL_ON_FAILURE`
(https://www.php.net/manual/en/function.filter-var.php):

```php
declare(strict_types=1);

$page = filter_var($input, FILTER_VALIDATE_INT, [
    'options' => ['min_range' => 1, 'max_range' => 500],
    'flags'   => FILTER_NULL_ON_FAILURE,
]) ?? 1;

$sort = in_array($input, ['title', 'postDate'], true) ? $input : 'postDate';
```

Validation-filter notes (https://www.php.net/manual/en/filter.constants.validation.php):

- `FILTER_VALIDATE_INT` trims the string first; pass `min_range`/`max_range` rather than
  checking after.
- `FILTER_VALIDATE_EMAIL` checks syntax only - the only real proof of an address is a
  confirmation email.
- `FILTER_VALIDATE_URL` does **not** validate the scheme: `javascript:` and `file:` URLs
  can pass. Check `parse_url($url, PHP_URL_SCHEME)` against `['http', 'https']`, and
  check the host against an allow-list before fetching it (SSRF).
- Use `declare(strict_types=1)` and typed parameters so internal calls cannot silently
  coerce.

## Type Juggling

- PHP 8.0 changed number-to-string comparison: `0 == "foo"` is now `false`
  (https://www.php.net/manual/en/migration80.incompatible.php). Loose comparison is
  still a bug class - use `===`, `in_array($v, $list, true)`, and `match` (which compares
  strictly) instead of `switch` (which does not).
- Compare secrets and tokens with `hash_equals($known, $userSupplied)` - constant-time,
  user value second (https://www.php.net/manual/en/function.hash-equals.php).
- Array-for-string attacks: `strcmp()` and friends on an array throw a `TypeError` in
  PHP 8 rather than returning `null`, so the old auth-bypass is gone - but an uncaught
  `TypeError` is a 500 and a log flood. Check `is_string()` first.
- JSON: `json_decode($body, true, 512, JSON_THROW_ON_ERROR)` and then validate the
  decoded structure - decoding is parsing, not validation.

## Files, Paths and Commands

```php
// Path traversal: resolve, then prove containment
$base = realpath(Craft::getAlias('@storage/exports'));
$path = realpath($base . DIRECTORY_SEPARATOR . basename($requested));
if ($path === false || !str_starts_with($path, $base . DIRECTORY_SEPARATOR)) {
    throw new \yii\web\NotFoundHttpException();
}

// Commands: pass an argument array - proc_open() then bypasses the shell (PHP 7.4+)
$proc = proc_open(['convert', $in, '-resize', '800x', $out], $spec, $pipes);
```

- Never `include`/`require` a path built from input (local file inclusion), and never
  `extract()` request arrays into local variables.
- If a shell string is unavoidable, `escapeshellarg()` every argument; better, use the
  array form above or a library.
- File uploads: see `craft-uploads-assets.md` - check extension against an allow-list,
  generate the stored filename, never trust the client's MIME type.
- XML: libxml 2.9+ disables external entity loading by default and PHP 8.0 deprecated
  `libxml_disable_entity_loader()`; do not pass `LIBXML_NOENT` on untrusted XML.
- Regex: never build a pattern from input without `preg_quote()`; cap input length
  before running complex patterns (ReDoS).
- Redirects: send users only to relative paths or an allow-listed host; in Craft forms use
  `redirectInput()` (hashed).

## Mass Assignment

Yii models assign only **safe attributes** - those with validation rules in the current
scenario - when you call `load()` or `setAttributes()`
(https://www.yiiframework.com/doc/guide/2.0/en/structure-models#safe-attributes):

```php
public function rules(): array
{
    return [
        [['name', 'bio'], 'string', 'max' => 500],
        [['!ownerId', '!isApproved'], 'integer'],  // "!" = validated but never mass-assigned
    ];
}
```

- Never pass `false` for `$safeOnly` on request data.
- For elements, the same risk is custom fields: front-end entry and profile forms can set
  **any** field, not just the ones rendered (`craft-access-control.md`).

## Review Checklist

```bash
rg -n '\$_(GET|POST|REQUEST|COOKIE)\b' --type php           # prefer the request API
rg -n '\b(extract|parse_str)\s*\(\s*\$_' --type php         # variable injection
rg -n '\b(include|require)(_once)?\b[^;]*\$_' --type php    # LFI
rg -n '(^|[^>:\w])(shell_exec|exec|system|passthru|popen)\s*\(' --type php
rg -n '[^=!]==[^=]' --type php | rg -i 'token|hash|password|secret|role'
rg -n 'setAttributes\([^)]*,\s*false' --type php            # mass assignment
```

- [ ] Every request value checked for type and allow-listed values before use
- [ ] Secrets compared with `hash_equals()`; no loose comparisons on auth data
- [ ] File paths resolved and containment-checked; no include/extract on input
- [ ] Commands built as argument arrays; URLs checked for scheme and host
- [ ] Models expose only intended safe attributes
