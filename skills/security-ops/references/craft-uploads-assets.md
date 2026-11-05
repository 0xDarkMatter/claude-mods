# Craft Uploads and Asset Volumes

Which files Craft accepts, where they land, who can read them, and the image-transform
endpoint behind Craft's worst recent CVE. Craft CMS 3/4/5; facts verified 2026-10-05
against https://craftcms.com/docs/5.x/reference/config/general.html (G5) and
https://craftcms.com/docs/5.x/reference/element-types/assets.html (AST).

## Contents

- Allowed File Types
- Public and Private Volumes
- Upload Paths and Permissions
- Image Transforms
- Web Server Defence in Depth
- Review Checklist

## Allowed File Types

`allowedFileExtensions` (G5) defaults to about 100 extensions. It already excludes `php`,
`html` and `htm`, but it **includes** types that matter on a same-origin volume:

| Extension | Risk when served from your own origin | Action |
|---|---|---|
| `svg` | script inside SVG runs on your origin | keep `sanitizeSvgUploads` at `true` (default; G5: "should definitely be enabled" for untrusted sources) |
| `js` | an uploaded script satisfies `script-src 'self'`, defeating your CSP | remove unless editors truly upload scripts |
| `json`, `txt`, `csv` | harmless alone; sniffed as HTML by old clients without `nosniff` | send `X-Content-Type-Options: nosniff` |
| `pdf` | can carry JavaScript for PDF viewers | acceptable; serve as a download for untrusted uploaders |
| `swf`, `fla` | obsolete; no reason to accept | remove |

Trim the list in `config/general.php` - `extraAllowedFileExtensions` only *adds*, so use
`allowedFileExtensions` with an explicit list to remove entries. Craft's securing guide
says to review this setting (https://craftcms.com/knowledge-base/securing-craft).
Other defaults worth keeping: `sanitizeCpImageUploads` (`true`), `maxUploadFileSize`
(16 MB; PHP's `upload_max_filesize` and `post_max_size` also apply).

OWASP's upload controls apply on top: an extension allow-list, a generated filename, size
limits, and never trusting the client's Content-Type, which "is trivial to spoof"
(https://cheatsheetseries.owasp.org/cheatsheets/File_Upload_Cheat_Sheet.html).

## Public and Private Volumes

- A filesystem's "Files in this filesystem have public URLs" setting decides whether Craft
  generates URLs for its files (AST). For a local filesystem with public URLs, the base
  path must sit inside the web root - so everything in it is downloadable by anyone who
  can guess or learn a path.
- **Private files** (form attachments, CVs, invoices, member downloads) go on a filesystem
  with public URLs **off** and a base path **outside** the web root
  (https://craftcms.com/knowledge-base/securing-craft). Their `asset.url` is empty; serve
  them through a controller that checks access:

```php
public function actionDownload(int $assetId): \yii\web\Response
{
    $this->requireLogin();
    $asset = \craft\elements\Asset::find()->id($assetId)->one();
    if (!$asset || !Craft::$app->getElements()->canView($asset)) {
        throw new \yii\web\ForbiddenHttpException();
    }
    return $this->response->sendStreamAsFile($asset->getStream(), $asset->getFilename());
}
```

- Swap `canView()` for your own ownership rule when the audience is front-end members
  rather than CP users (`craft-access-control.md`).
- Volumes can store transforms on a separate filesystem, which keeps generated thumbnails
  of private images out of a public path (AST).
- Formie file-upload fields write into a volume you choose - point them at a private one.

## Upload Paths and Permissions

- `AssetsController` allows anonymous access only to `generate-thumb` and
  `generate-transform`; every upload action requires a logged-in user
  (https://docs.craftcms.com/api/v5/craft-controllers-assetscontroller.html).
- Per-volume permissions (Craft 4/5): view, save, delete, replace files, edit images,
  create subfolders - each with a "peer" variant for files other users uploaded. Front-end
  member groups should get save on their own volume and **no** peer permissions.
- Assets fields: set "Restrict allowed file types" (`restrictFiles` + `allowedKinds`) and
  `restrictLocation` so a field cannot be used to drop arbitrary files into a public
  volume (https://docs.craftcms.com/api/v5/craft-fields-assets.html).
- Third-party upload paths (Formie, Guest Entries, custom controllers) bypass the CP
  upload UI - review each for size limits, type limits and the destination volume.

## Image Transforms

| Advisory | What | Fixed in |
|---|---|---|
| CVE-2025-32432 (critical, exploited, CISA KEV) | unauthenticated RCE via `actions/assets/generate-transform` | 3.9.15, 4.14.15, 5.6.17 |
| GHSA-5pgf-h923-m958 | anonymous `generate-transform` exposed private assets | 4.17.8, 5.9.14 |

Sources: https://github.com/craftcms/cms/security/advisories and
https://craftcms.com/knowledge-base/craft-cms-cve-2025-32432 (which also lists the
incident-response steps: take the site offline, clean it, update, rotate the security key
and credentials, force password resets).

- Patching is the fix; these were not configuration problems.
- Ad-hoc transforms (arbitrary sizes from templates or GraphQL) let a visitor request
  unbounded variants. Craft documents no "named transforms only" switch; prefer named
  transforms in templates, disable the GraphQL `@transform` directive where unused, and
  rate-limit `generate-transform` at the CDN or web server.
- Image processing runs ImageMagick when available. Keep it patched and restrict its
  coders with a `policy.xml` when untrusted users upload images.

## Web Server Defence in Depth

Even with `php` excluded, make upload directories non-executable so a future bypass
cannot run code:

```nginx
# nginx: never execute PHP under public upload roots
location ~* ^/(uploads|assets|files)/.*\.(php|phtml|phar)$ { deny all; }
```

```apache
# Apache: .htaccess inside each public upload root
<FilesMatch "\.(php|phtml|phar)$">
  Require all denied
</FilesMatch>
```

Add `X-Content-Type-Options: nosniff` site-wide (`secure-headers.md`).

## Review Checklist

```bash
rg -n 'allowedFileExtensions|extraAllowedFileExtensions|sanitizeSvgUploads|maxUploadFileSize' config/
rg -n 'hasUrls: true' config/project/                         # which filesystems/volumes are public
composer show craftcms/cms | rg '^versions'                    # transform CVE floors
```

- [ ] `sanitizeSvgUploads` on; `js`, `swf` and unneeded types removed from the allow-list
- [ ] Private uploads (forms, member files) on a filesystem with public URLs off, outside the web root
- [ ] Private files served only through a controller with an access check
- [ ] Member groups have no peer asset permissions; Assets fields restrict kinds and location
- [ ] Craft above the CVE-2025-32432 and GHSA-5pgf fixed versions
- [ ] Upload directories cannot execute PHP; `nosniff` sent
