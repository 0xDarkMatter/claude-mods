# Codeception (Craft's Test Framework)

Craft core ships a Codeception-based test framework (`craft\test\*`): a Codeception
module that boots Craft against a throwaway database, element fixtures, and helpers.
Use Codeception 5 on Craft 5 (core's own dev constraint is `codeception/codeception
^5.2`; latest 5.3.7, Packagist 2026-10-05).

**Documentation gap (verified 2026-10-05):** craftcms.com has testing docs only for
[Craft 3.x and 4.x](https://craftcms.com/docs/4.x/testing/); there is no 5.x testing
section. The framework still ships in Craft 5, so the 4.x docs describe the *shape*, and
core's 5.x example suite
([`src/test/internal/example-test-suite`](https://github.com/craftcms/cms/tree/5.x/src/test/internal/example-test-suite))
is the source of truth for current file contents and env names.

## Contents

- [What to test in an agency build](#what-to-test-in-an-agency-build)
- [Setup](#setup)
- [Module config (`codeception.yml`)](#module-config-codeceptionyml)
- [Fixtures](#fixtures)
- [Unit tests](#unit-tests)
- [Functional tests](#functional-tests)
- [Code style and static analysis (ECS, PHPStan)](#code-style-and-static-analysis-ecs-phpstan)

## What to test in an agency build

Most Craft sites are configuration plus Twig; the PHP worth testing lives in modules:

- Services with real logic (pricing, eligibility, feed import mapping, API sync).
- Event handlers that must *not* double-fire (drafts, revisions, propagation - see
  [plugin-development.md](plugin-development.md#registration-patterns)).
- Controllers that accept front-end input (validation, CSRF, permission checks).
- Queue jobs (idempotency on retry).
- A few functional smoke tests: key templates return 200 with seeded content.

Don't test Craft itself (that saving an entry saves it) - that is ceremony.

## Setup

```bash
ddev composer require --dev codeception/codeception codeception/module-asserts \
  codeception/module-yii2 vlucas/phpdotenv
ddev craft tests/setup            # scaffolds tests/ + codeception.yml from core's example suite
ddev exec vendor/bin/codecept build
ddev exec vendor/bin/codecept run unit
```

Resulting layout (from the setup docs and the 5.x example suite):

```
codeception.yml          # paths, params: [tests/.env], \craft\test\Craft module config
tests/
├── .env                 # CRAFT_DB_DSN, CRAFT_DB_USER, CRAFT_DB_PASSWORD,
│                        # CRAFT_DB_TABLE_PREFIX, SECURITY_KEY  (5.x names)
├── _bootstrap.php       # defines CRAFT_TESTS_PATH etc. (PHP constants), then
│                        # TestSetup::configureCraft()
├── _craft/
│   ├── config/test.php  # returns TestSetup::createTestCraftObjectConfig()
│   ├── config/db.php
│   ├── storage/ templates/ migrations/ translations/
├── unit/  unit.suite.yml      + _bootstrap.php
└── functional/ functional.suite.yml + _bootstrap.php
```

Point `tests/.env` at a **separate** database - the module drops every table in it
(DDEV: create a second database, or a second DDEV project for tests). The 4.x docs show
older env names (`DB_DSN`); use the 5.x `CRAFT_DB_*` names.

## Module config (`codeception.yml`)

```yaml
modules:
  config:
    \craft\test\Craft:
      configFile: 'tests/_craft/config/test.php'
      entryUrl: 'https://my-site.ddev.site/index.php'
      projectConfig:
        folder: 'config/project'   # copied in and applied before each test; key is
                                   # `folder` (not `file`), relative to repo root
      migrations: []
      plugins: []                  # [{ class: ..., handle: ... }] if not using projectConfig
      cleanup: true                # Yii2 module: clean fixtures after each test
      transaction: true            # wrap each test in a DB transaction
      dbSetup: { clean: true, setupCraft: true }
```

`dbSetup.clean` drops all tables, `setupCraft` runs Craft's install migration, and
`projectConfig.folder` gives the test install your real sections and fields - the
setting that makes fixtures by handle work. Source:
[config options](https://craftcms.com/docs/4.x/testing/framework/config-options.html).

## Fixtures

Element fixtures are abstract classes you subclass: `EntryFixture`, `AssetFixture`,
`CategoryFixture`, `GlobalSetFixture`, `TagFixture`, `UserFixture`
(`craft\test\fixtures\elements\*`). Data files return arrays and resolve IDs by handle:

```php
// tests/fixtures/data/entries.php
return [
    [
        'sectionId' => $this->sectionIds['news'],
        'typeId'    => $this->typeIds['news']['article'],
        'title'     => 'Fixture article',
        'field:summary' => 'Custom field values use the field: prefix',
    ],
];
```

```php
// tests/unit/NewsServiceTest.php
public function _fixtures(): array
{
    return ['entries' => ['class' => \tests\fixtures\EntriesFixture::class]];
}
```

Source: [fixtures](https://craftcms.com/docs/4.x/testing/testing-craft/fixtures.html).
Categories/tags resolve via `$this->groupIds`, assets via volume and folder IDs.

## Unit tests

The `\craft\test\Craft` actor adds element helpers - `saveElement`, `deleteElement`,
`assertElementsExist` - plus queue helpers (`runQueue`, `assertPushedToQueue`),
`expectEvent`, `mockCraftMethods`, and `resetProjectConfig`.

```php
public function testArticleScoreUsesSummaryLength(): void
{
    $entry = Entry::find()->section('news')->title('Fixture article')->one();
    $this->assertSame(42, Module::getInstance()->scoring->score($entry));
}

public function testSavingArticleQueuesSync(): void
{
    $this->tester->saveElement($article);
    // matches the job's description string; signature: assertPushedToQueue(string $description)
    $this->tester->assertPushedToQueue('Syncing article');
}
```

`assertPushedToQueue()` only asserts presence. For the negative case (a draft save must
*not* queue a sync - the double-fire bug from
[plugin-development.md](plugin-development.md#registration-patterns)), count rows in the
`queue` table before and after the save. Helper signatures:
[`src/test/Craft.php`](https://github.com/craftcms/cms/blob/5.x/src/test/Craft.php).

## Functional tests

`\craft\test\Craft` extends Codeception's Yii2 module, so functional Cests get
`amOnPage`, `see`, `seeResponseCodeIs`, `amLoggedInAs`:

```php
public function homepageRenders(FunctionalTester $I): void
{
    $I->amOnPage('?p=/');
    $I->seeResponseCodeIs(200);
}
```

Requests are in-process (no web server), addressed as `?p=<uri>`; CP pages use the
`cpTrigger`, plugin actions `?p=actions/<plugin>/<controller>/<action>`. Limitations:
disable `transaction` for acceptance-style tests, and MyISAM search-index rows survive a
rollback. For real-browser checks, run Playwright or Cypress against the DDEV URL
instead (see `playwright-ops`).

Pest via a third-party plugin is an alternative some teams use; the official docs
document only Codeception.

## Code style and static analysis (ECS, PHPStan)

- **ECS:** `craftcms/ecs` (install `craftcms/ecs:dev-main --dev`; needs
  `minimum-stability: dev` + `prefer-stable: true`) wraps Easy Coding Standard with
  Craft's PSR-12 variant. Its `SetList` has only `CRAFT_CMS_3` and `CRAFT_CMS_4` - use
  `CRAFT_CMS_4` on Craft 5 (core does). Run `vendor/bin/ecs check --ansi`, fix with
  `--fix`. Source: [craftcms/ecs](https://github.com/craftcms/ecs).
- **PHPStan:** `craftcms/phpstan` provides a base `phpstan.neon` with Craft stubs:
  `includes: [vendor/craftcms/phpstan/phpstan.neon]`, start at `level: 0` on `modules/`,
  raise the level as the codebase allows. Run with `--memory-limit=1G`.

Wire all three into one `composer check` (or `just check`) script so CI and humans run
the same gate.
