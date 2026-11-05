# Craft Access Control

User permissions, element authorisation, and controller access rules for Craft CMS 3/4/5.
The recurring bug is mistaking an *authentication* gate for an *authorisation* check.
Facts verified 2026-10-05 against craftcms.com/docs/5.x and craftcms/cms source.

## Contents

- The Permission Model
- Controller allowAnonymous
- The require Helpers
- Element Authorisation
- Front-End Entry and User Forms
- Templates and Element Queries
- Review Checklist

## The Permission Model

- Permissions attach to users and user groups and are additive
  (https://craftcms.com/docs/5.x/system/user-management.html). Admins bypass every check:
  `User::can()` returns `true` for admins, and for everyone on the Solo edition.
- Check in PHP with `Craft::$app->getUser()->checkPermission('name')` or
  `$user->can('name')`; in Twig with `currentUser.can('name')`.
- Content permissions are keyed by UID, and Craft 4/5 names differ from Craft 3:

| Area | Craft 4/5 | Craft 3 |
|---|---|---|
| Entries | `viewEntries:<sectionUid>`, `saveEntries:`, `deleteEntries:`, peer variants (`viewPeerEntries:`, `savePeerEntries:`...), draft variants | `editEntries:`, `publishEntries:`, `editPeerEntries:`... |
| Assets | `viewAssets:<volumeUid>`, `saveAssets:`, `deleteAssets:`, `replaceFiles:`, `editImages:`, peer variants | `viewVolume:`, `saveAssetInVolume:`, `viewPeerFilesInVolume:`... |
| System | `accessCp`, `accessSiteWhenSystemIsOff`, `registerUsers`, `administrateUsers`, `assignUserGroup:<uid>` | similar, no UID-keyed group assignment in early 3.x |

- Least privilege: grant `admin` to as few people as possible - an admin can author
  templates and system messages (`twig-template-injection.md`). `administrateUsers` is
  near-admin: GHSA-6qw4-cjqw-fj72 let it mint an admin password-reset URL (fixed 5.10.11).

## Controller allowAnonymous

`craft\web\Controller::$allowAnonymous` defaults to `ALLOW_ANONYMOUS_NEVER`: "An active
user session is required by default" (https://craftcms.com/docs/5.x/extend/controllers.html).

| Value | Meaning |
|---|---|
| `false` / `self::ALLOW_ANONYMOUS_NEVER` | guests get 403 (503 when the system is offline) |
| `true` / `self::ALLOW_ANONYMOUS_LIVE` | **every action** open to guests while the site is live |
| `self::ALLOW_ANONYMOUS_OFFLINE` | open to guests only while the system is off |
| `['save-guest-entry']` | listed actions only, live only |
| `['ping' => self::ALLOW_ANONYMOUS_LIVE \| self::ALLOW_ANONYMOUS_OFFLINE]` | per-action bitmask |

The pitfalls, all from `craft\web\Controller` source:

1. **It only gates guests.** A logged-in user passes for any site request, whatever their
   permissions. `allowAnonymous` is never authorisation; the action must still check
   permissions or ownership itself.
2. **`true` opens actions written later.** A controller that starts with one public action
   and `$allowAnonymous = true` silently exposes every action added afterwards. Use the
   array form so each public action is named.
3. **`beforeAction()` overrides must call `parent::beforeAction($action)`.** The CSRF
   check and the anonymous gate both live there; skipping the parent call skips both.
4. **A valid site token skips the gate** on non-CP requests (`hasValidSiteToken()`), so
   preview-token routes need their own checks.
5. **CSRF still applies** to anonymous POSTs - "open to guests" does not mean "no token".

```php
class ReportsController extends \craft\web\Controller
{
    // WRONG: protected array|bool|int $allowAnonymous = true;
    protected array|bool|int $allowAnonymous = ['public-summary'];

    public function actionExport(): \yii\web\Response
    {
        $this->requirePostRequest();
        $this->requirePermission('myModule-exportReports');
        // ...
    }
}
```

## The require Helpers

Call these at the top of each action, or in `beforeAction()`:

| Helper | Failure |
|---|---|
| `requireLogin()` | redirect to login |
| `requireGuest()` | redirect (3.4+) |
| `requirePermission('name')` | 403 |
| `requireAdmin($requireAdminChanges = true)` | 403; by default also 403 when `allowAdminChanges` is off |
| `requireElevatedSession()` | 403 - re-prompts for the password; use before destructive or account-changing actions |
| `requirePostRequest()` | 405 - state changes must not be GET |
| `requireAcceptsJson()` | 400 |
| `requireCpRequest()` / `requireSiteRequest()` | 400 (3.1+) |

Twig equivalents for templates: `{% requireLogin %}`, `{% requireGuest %}`,
`{% requirePermission 'name' %}`, `{% requireAdmin %}` (Craft 4/5)
(https://craftcms.com/docs/5.x/reference/twig/tags.html). They run only when Craft renders
the template - a statically cached page never executes them (`craft-csrf-forms.md`).

## Element Authorisation

- Craft 4.0+ elements expose `canView()`, `canSave()`, `canDuplicate()`, `canDelete()`,
  `canDeleteForSite()` and `canCreateDrafts()`, each taking a `User`; Craft 4.3+ adds the
  service form `Craft::$app->getElements()->canView($element, $user)`
  (https://docs.craftcms.com/api/v5/craft-services-elements.html).
- `canView()` answers "may this user open the element's **edit page**", not "may this
  visitor see it on the front end". Front-end visibility is whatever your query and
  template allow.
- Custom element types and plugins extend the rules through `Elements::EVENT_AUTHORIZE_VIEW`,
  `_SAVE`, `_DELETE`, `_DUPLICATE`, `_CREATE_DRAFTS` (4.3+): set
  `$event->authorized = true` to grant. Base-class defaults are restrictive.
- Custom controllers that load an element by an ID from the request must authorise that
  element, not just the action - otherwise it is an IDOR:

```php
$entry = Entry::find()->id($this->request->getRequiredBodyParam('entryId'))->one();
if (!$entry || !Craft::$app->getElements()->canSave($entry)) {
    throw new \yii\web\ForbiddenHttpException();
}
```

## Front-End Entry and User Forms

- **`entries/save-entry`** enforces the logged-in user's section permissions; "It is not
  currently possible to allow anonymous access without a plugin"
  (https://craftcms.com/docs/5.x/reference/controller-actions.html). The user can change
  **any** custom field on the entry - hiding or omitting inputs "is not enough".
- **Guest submissions** need the first-party Guest Entries plugin
  (https://github.com/craftcms/guest-entries): restrict it to dedicated sections, default
  new entries to disabled, and use its `beforeSaveEntry` event for spam checks. "Omitting
  a field from your form does not mean it is safe from tampering!"
- **Public registration** (`users.allowPublicRegistration`, off by default) places every
  registrant in the **Default User Group** - that group's permissions are granted to
  anyone on the internet. Keep it permission-free. Craft's docs warn that granting
  administrative permissions to front-end users "opens your site up to permissions
  escalation" (https://craftcms.com/docs/5.x/reference/controller-actions.html).
- **Profile forms** (`users/save-user`) let users update all their own custom fields.
  Add a user editability condition to any field that must be tamper-proof (a
  "verified" flag, a membership tier).
- **Password reset**: `preventUserEnumeration` (default `false`) makes the forgot-password
  flow always succeed and randomises response timing. Turn it on for sites with public
  accounts. Keep Craft current: GHSA-p8x7-9vfw-p7vc (reset flow to admin takeover) was
  fixed in 5.10.8.

## Templates and Element Queries

- Entry queries default to `live` status; drafts, revisions, provisional drafts and
  trashed elements are excluded unless the template asks for them
  (https://craftcms.com/docs/5.x/reference/element-types/entries.html). A template that
  passes `.status(null)` or `.drafts()` from request input can expose unpublished content.
- Element queries do **not** apply per-user permissions. A members-only section is
  members-only only if its templates check `currentUser` (or a permission) before
  querying, and the pages are not statically cached.
- Never let a query parameter choose `status`, `drafts`, `site` or `section` directly;
  see `php-sql-queries.md` for element-query parameter injection.

## Review Checklist

```bash
rg -n 'allowAnonymous\s*=\s*(true|self::ALLOW_ANONYMOUS)' --type php
rg -n 'function beforeAction' --type php        # each must return parent::beforeAction()
rg -n 'function action\w+' --type php           # each needs a require* or explicit check
rg -n "\.(status|drafts|revisions|trashed)\([^)]*craft\.app\.request" templates/
```

- [ ] No controller uses `$allowAnonymous = true`; anonymous actions are listed by name
- [ ] Every action that changes state calls `requirePostRequest()` and a permission or ownership check
- [ ] Every `beforeAction()` override returns `parent::beforeAction($action)`
- [ ] Elements loaded by request ID are authorised (`canView`/`canSave`) before use
- [ ] Default User Group holds no meaningful permissions; tamper-sensitive user fields have editability conditions
- [ ] `preventUserEnumeration` on for public-account sites; admins kept to a minimum
