# Plugin & Module Development

Load this when writing PHP that extends Craft: a project module, a distributable
plugin, a custom field/element type, a queue job, or a content migration.

## Contents

- [Module or plugin?](#module-or-plugin)
- [Scaffold with the generator](#scaffold-with-the-generator)
- [Plugin anatomy](#plugin-anatomy)
- [Registration patterns](#registration-patterns)
- [Migrations](#migrations)
- [Queue jobs](#queue-jobs)

## Module or plugin?

| Build a... | When |
|------------|------|
| **Module** | Project-specific code that ships with one site (`modules/`, registered in `config/app.php`). The usual agency answer |
| **Plugin** | Reusable across sites or sold on the Plugin Store (a Composer package of `type: craft-plugin`) |

Both are Yii 2 modules with Craft conventions: services hold business logic, controllers
handle requests, everything else hooks in through **events**. Keep logic out of Twig -
a service method is testable ([codeception.md](codeception.md)); a 40-line Twig macro is not.

## Scaffold with the generator

```bash
composer require craftcms/generator --dev     # under DDEV: ddev composer require ...
php craft make module                          # or: make plugin
php craft make controller --module=site        # component into an existing module
php craft make                                 # lists every component type your version supports
```

Source: [Craft generator docs](https://craftcms.com/docs/5.x/extend/generator.html). The
generator writes code that already follows the
[coding guidelines](https://craftcms.com/docs/5.x/extend/coding-guidelines.html) - start
there rather than hand-rolling boilerplate.

## Plugin anatomy

```
my-plugin/
├── composer.json          # "type": "craft-plugin", PSR-4 autoload, extra.handle
├── src/
│   ├── Plugin.php         # init(): register services, event handlers
│   ├── services/          # business logic (Plugin::getInstance()->myService)
│   ├── controllers/       # site + CP actions (/actions/my-plugin/<controller>/<action>)
│   ├── elements/          # custom element types
│   ├── fields/            # custom field types
│   ├── jobs/              # queue jobs (extend craft\queue\BaseJob)
│   ├── models/Settings.php
│   └── migrations/        # Install.php + versioned migrations
└── CHANGELOG.md
```

## Registration patterns

```php
// Plugin.php / Module.php, inside init() - or attachEventHandlers() called from it
use craft\base\Element;
use craft\elements\Entry;
use craft\events\ModelEvent;
use craft\helpers\ElementHelper;
use yii\base\Event;

public static function config(): array
{
    // Services as components: lazily constructed, injectable, mockable in tests
    return ['components' => ['sync' => ['class' => SyncService::class]]];
}

public function init(): void
{
    parent::init();
    Event::on(Entry::class, Element::EVENT_AFTER_SAVE, function (ModelEvent $e) {
        /** @var Entry $entry */
        $entry = $e->sender;
        if (ElementHelper::isDraftOrRevision($entry) || $entry->propagating) {
            return;  // saves fire for drafts, revisions, and every site - filter first
        }
        // push slow work to the queue, never do it inline in a save handler
    });
}
```

The `config()` components form is from the
[services docs](https://craftcms.com/docs/5.x/extend/services.html). The guard in that
handler is the most-missed line in Craft event code: one CP save can
fire `EVENT_AFTER_SAVE` many times (each site it propagates to, plus drafts and
revisions). Unguarded handlers double-send webhooks and re-index search N times.

Register Twig extensions with `Craft::$app->view->registerTwigExtension(...)`, CP
templates via `View::EVENT_REGISTER_CP_TEMPLATE_ROOTS`, and custom field/element types
via their `EVENT_REGISTER_*_TYPES` events.

## Migrations

| Kind | Purpose | Create / run |
|------|---------|--------------|
| **Install** | A plugin's tables on install | `migrations/Install.php` |
| **Plugin** | Schema changes between plugin versions | `php craft migrate/create <name> --plugin=handle` |
| **Content** | Project data transforms (backfill a field, merge entry types) | `php craft migrate/create <name>` - lives in `migrations/` |

All run via `php craft up`, which also applies Project Config. Content migrations are
version-controlled and run once per environment - the right home for any data change
you would otherwise click through by hand on prod. Test them on a copy of the
production database first (`ddev pull`, see [ddev.md](ddev.md)).

**Never write Project Config from a migration with raw YAML.** Change schema in the CP
(dev, `allowAdminChanges: true`), commit `config/project/`, and let `php craft up`
apply it; production runs with `allowAdminChanges` set to `false`.

## Queue jobs

Anything slow (API sync, bulk resave, transform generation, webhook fan-out) goes on the
queue:

```php
Craft::$app->getQueue()->push(new SyncEntryJob(['entryId' => $entry->id]));
```

Jobs extend `craft\queue\BaseJob`, implement `execute($queue)`, report progress with
`$this->setProgress()`, and should be idempotent (a retried job must not double-apply).
How the queue actually runs in production is a hosting decision - see
[performance.md](performance.md#queue).
