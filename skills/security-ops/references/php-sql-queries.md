# PHP SQL: Query Builder versus Raw SQL

Injection-safe database access in Craft/Yii 2 and plain PDO, and the element-query
parameter syntax that turns request input into query logic. Facts verified 2026-10-05
against yiisoft/yii2 and craftcms/cms source, php.net, and the OWASP SQL Injection
Prevention Cheat Sheet
(https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html).

## Contents

- The Rule
- Yii Query Builder
- Identifiers Cannot Be Bound
- Raw SQL in Craft
- Plain PDO
- Element Query Parameter Injection
- Review Checklist

## The Rule

Values travel as bound parameters; identifiers (columns, tables, sort directions) come
from an allow-list. OWASP's first option is parameterised queries; escaping by hand is
"strongly discouraged".

## Yii Query Builder

Craft's `craft\db\Query` and element queries sit on Yii 2's query builder
(https://www.yiiframework.com/doc/guide/2.0/en/db-query-builder). Its formats differ in
safety:

```php
use craft\db\Query;

// SAFE - hash format: values bound, column names quoted
(new Query())->from('{{%myplugin_orders}}')->where(['userId' => $userId, 'status' => 'paid']);

// SAFE - operator format: values bound; LIKE wildcards in the value escaped by default
->andWhere(['like', 'reference', $search]);
->andWhere(['>=', 'total', $minimum]);

// SAFE - string format WITH named parameters
->andWhere('dateCreated > :since', [':since' => $since]);

// WRONG - string format with interpolation: SQL injection
->andWhere("reference = '$search'");
->andWhere('total >= ' . $minimum);
```

Every `where`/`andWhere`/`orWhere`/`having`/`join` condition follows the same rule: an
array, or a string with placeholders - never a string built from input.

## Identifiers Cannot Be Bound

Placeholders bind values only. Yii quotes identifiers - but `Schema::quoteColumnName()`
returns a name **unchanged** when it contains `(`, `[[` or `{{`, and `select()`/`groupBy()`
skip quoting for any column containing `(` (yiisoft/yii2 `framework/db/Schema.php`,
`QueryBuilder.php`). So a request-controlled column name is raw SQL:

```php
// WRONG - ?sort=(SELECT password FROM users LIMIT 1) passes through unquoted
$query->orderBy($this->request->getQueryParam('sort'));

// CORRECT - map input onto known columns and directions
$columns = ['title' => 'title', 'date' => 'postDate', 'price' => 'price'];
$column  = $columns[$this->request->getQueryParam('sort')] ?? 'postDate';
$dir     = $this->request->getQueryParam('dir') === 'asc' ? SORT_ASC : SORT_DESC;
$query->orderBy([$column => $dir]);
```

The same applies to `select()`, `groupBy()`, `from()`, table prefixes and `LIMIT` values
that arrive as strings - cast limits with `(int)` and allow-list everything else.

## Raw SQL in Craft

When the builder cannot express a query, bind through the command:

```php
$rows = Craft::$app->getDb()->createCommand(
    'SELECT id, total FROM {{%myplugin_orders}} WHERE userId = :uid AND total > :min',
    [':uid' => $userId, ':min' => $minimum]
)->queryAll();
```

- `{{%table}}` applies the table prefix; `[[column]]` quotes a column name. Neither is a
  bound value - they are for constants you write, not input.
- `createCommand($sql)` with an interpolated `$sql` is the same bug as string-format
  `where()`. So is `->execute()` on a concatenated string.
- Migrations and console commands are lower risk but follow the same habit - input
  arrives there from CSV imports and API payloads too.

## Plain PDO

For code outside Craft (legacy scripts, small APIs):

```php
$pdo = new PDO($dsn, $user, $pass, [
    PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
    PDO::ATTR_EMULATE_PREPARES   => false,   // pdo_mysql emulates by default
    PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
]);
$stmt = $pdo->prepare('SELECT id FROM users WHERE email = ?');
$stmt->execute([$email]);

// LIKE: the wildcard goes in the bound value, never in the SQL text
$stmt = $pdo->prepare('SELECT id FROM posts WHERE title LIKE ?');
$stmt->execute(['%' . addcslashes($term, '%_\\') . '%']);
```

From https://www.php.net/manual/en/pdo.prepared-statements.php: parameters need no
quoting, but if any other part of the query is built from unescaped input, "SQL
injection is still possible"; a placeholder inside a quoted literal (`LIKE '%?%'`) does
not work. `ATTR_EMULATE_PREPARES` set to `false` uses real server-side prepares on MySQL
(https://www.php.net/manual/en/pdo.setattribute.php).

## Element Query Parameter Injection

Craft element-query parameters are parsed by `Db::parseParam()`, which gives strings a
mini-language: comma-separated lists, `*` wildcards, and leading operators `not `, `!=`,
`<`, `<=`, `>`, `>=`, `=`, plus `:empty:` / `:notempty:` (craftcms/cms
`src/helpers/Db.php`). Request input passed straight in becomes query logic - not SQL
injection, but the attacker chooses *which* rows match:

```twig
{# WRONG - ?slug=* returns the first entry of any slug; ?slug=not%20x inverts the match #}
{% set entry = craft.entries.section('offers').slug(craft.app.request.getQueryParam('slug')).one() %}
```

```php
// CORRECT in PHP - escape the mini-language, then query
use craft\helpers\Db;

$slug  = (string)$this->request->getRequiredQueryParam('slug');
$entry = Entry::find()->section('offers')->slug(Db::escapeParam($slug))->one();

$id    = (int)$this->request->getRequiredQueryParam('id');   // ids: cast, no parsing needed
```

- `Db::escapeParam()` escapes commas, asterisks and colons and neutralises a leading
  operator; `Db::escapeCommas()` escapes commas only; `Db::escapeForLike()` escapes
  underscores for `LIKE`.
- Never let input pick `status`, `drafts`, `revisions`, `trashed`, `site` or `section` -
  see `craft-access-control.md`.
- `.search()` takes Craft's search syntax on purpose; cap its length, since complex
  searches are expensive.

## Review Checklist

```bash
# String conditions built from variables
rg -n "(where|andWhere|orWhere|having)\(\s*(\"[^\"]*\\\$|'[^']*'\s*\.\s*\\\$)" --type php
# Raw commands built from variables
rg -n 'createCommand\(\s*("[^"]*\$|[^,)]*\.\s*\$)' --type php
# Identifiers from requests
rg -n '(orderBy|groupBy|select|from)\([^)]*(getParam|getQueryParam|getBodyParam|\$_(GET|POST|REQUEST))' --type php
# Element-query params fed from request data in templates
rg -n '\.(id|slug|uri|search|relatedTo|section|status)\([^)]*craft\.app\.request' templates/
```

- [ ] No string-format condition or raw command contains interpolated input
- [ ] Sort/column/table names come from an allow-list; limits are cast to int
- [ ] PDO code uses real prepares and exception error mode
- [ ] Element-query values from requests are cast or `Db::escapeParam()`-escaped
- [ ] Query-controlling params (status, drafts, site, section) are never request-driven
