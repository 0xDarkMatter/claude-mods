# Config Options

Fixture: the three sections of DDEV's configuration/config.md that
scripts/check-ddev-facts.py --live reads, in the table form the real page uses.

## `database`

The type and version of the database engine the project should use.

| Type | Default | Usage
| -- | -- | --
| :octicons-file-directory-16: project | `mariadb:11.8` | The following database types are currently supported:<br>- MariaDB 5.5-10.8, 10.11, 11.4, 11.8, 12.3

## `nodejs_version`

Node.js version for the web container, managed by `n`.

| Value | Result
| -- | --
| `24` | Default version preinstalled in DDEV.
| `""` (empty) | Uses the version already included in the image.

## `php_version`

The PHP version the project should use.

| Type | Default | Usage
| -- |---------| --
| :octicons-file-directory-16: project | `8.4` | Can be `5.6` through `8.5`. New versions are added when released upstream.

## `project_tld`

Not read by the verifier.
