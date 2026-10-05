---
name: ddev-ops
description: "Use when a project has a .ddev/ folder or needs one: DDEV config and version pinning, config.local.yaml and .ddev/.env files, database import, snapshots and ddev pull providers, sanitised production data, Mutagen and WSL2 speed, add-ons, custom commands and hooks, Node and Vite ports, Xdebug, ddev share, router and port conflicts, upgrades and troubleshooting. Ships an auditor for the .ddev/ mistakes that break a team."
license: MIT
allowed-tools: "Read Edit Write Bash Glob Grep"
metadata:
  author: claude-mods
  related-skills: "craftcms-ops, security-ops, frontend-upgrade-ops, docker-ops, web-perf-ops"
---

# DDEV Operations

**Why:** DDEV is the local stack behind most PHP agency sites, and it fails quietly: a
default that moved under an unpinned project, a key it silently ignores, one developer's
setting committed for the whole team.

> Versions verified 2026-10-05 against DDEV v1.25.4. Fast-moving facts (defaults, PHP and
> Node.js end-of-life floors, built-in command names) live once in
> `assets/ddev-facts.json`; `scripts/check-ddev-facts.py --offline` fails if this skill's
> prose and that file disagree, and `--live` (weekly) fails when DDEV moves.

## Start here

1. **Read the project before changing it:** `.ddev/config.yaml`, any `config.*.yaml`,
   `ls -a .ddev/`, then `ddev describe` (URLs, ports, services) and `ddev version`.
2. **Audit it.** From the skill folder (the launcher finds a working Python 3.8+, which
   matters on Windows where `python3` is often a Store stub):

   ```bash
   bash scripts/run-python.sh scripts/audit-ddev-config.py /path/to/project
   bash scripts/run-python.sh scripts/audit-ddev-config.py /path/to/project --json | jq '.data[]'
   ```

   Exit 10 means findings (one per line: severity, check, file, detail); 0 means clean.
   Fix the `high` rows first. `--ignore <check>` documents a deliberate exception.
3. **Run everything through DDEV** - `ddev composer`, `ddev php`, `ddev npm`,
   `ddev exec` - so commands use the container's PHP and Node, not the host's.
4. **Snapshot before anything risky:** `ddev snapshot --name=before-<task>`.

## Hard rules

Rules 2, 3, 4, 6 and 8 were each seen in a 2026-10-05 read of 36 DDEV-based agency
repositories; the rest are quiet failures DDEV's own docs and source describe.

1. **Pin `php_version` and `database` to production.** Unpinned projects follow DDEV's
   defaults, which move: v1.25.0 switched PHP 8.3 to 8.4 and MariaDB 10.11 to 11.8.
   Also pin `nodejs_version` and `composer_version: "2"`.
2. **Per-developer settings never go in `config.yaml`.** `performance_mode`,
   `router_http_port`/`router_https_port`, `xdebug_enabled: true`, `bind_all_interfaces`
   and `host_db_port` belong in `.ddev/config.local.yaml` (gitignored) or
   `ddev config global`. Project values beat global ones, so a committed value pins
   every teammate.
3. **Retired keys do nothing.** DDEV parses `config.yaml` non-strictly:
   `mutagen_enabled: false` and `nfs_mount_enabled` are ignored, not obeyed.
4. **`upload_dirs` resolve from the docroot.** With `docroot: web`, `storage` means
   `web/storage`; a folder beside the docroot is `../storage`. Setting the list replaces
   the project type's defaults.
5. **No secrets in committed `.ddev/.env*` files.** Use the `.local` twin
   (`.ddev/.env.web.local`, gitignored since v1.25.4) and commit a `.example`.
6. **Never forward the host SSH agent into containers.** Every process in them -
   Composer and npm scripts included - could sign with every key the agent holds. Load
   one scoped key with `ddev auth ssh -f <key>`.
7. **Pull sanitised data; never push to production.** Anonymise where the data lives and
   pull the result; delete `db_push_command`/`files_push_command` from any recipe that
   can reach production. No raw production personal data on laptops.
8. **Don't keep project copies of DDEV's built-in commands** (`craft`, `npm`,
   `artisan`, `wp`...). A project command shadows the built-in and freezes an old
   version. Command files must have LF endings: DDEV skips CRLF ones with only a warning.
9. **Review an add-on before installing it.** Its Bash install actions run on your
   machine. Prefer official `ddev/` add-ons and pin `--version`.
10. **On Windows, keep projects inside the WSL2 filesystem**, never under `/mnt/c`.

## Route by task

| Task | Read |
|---|---|
| New or inherited project, version pinning, what to commit, env files, upgrading DDEV | [config-and-env.md](references/config-and-env.md) |
| Import/export, snapshots, seed and reset, changing engine, `ddev pull` recipes, sanitised data | [database.md](references/database.md) |
| Slow project, Mutagen, `upload_dirs`, WSL2, choosing a Docker provider | [performance.md](references/performance.md) |
| Add-ons (Redis, search, cron), custom commands, hooks, daemons, extra services, PHP ini, SSH keys | [extending.md](references/extending.md) |
| Node.js version, npm/pnpm/yarn, Vite or other dev servers and their ports | [frontend-node.md](references/frontend-node.md) |
| Xdebug, XHGui profiling, Mailpit, `ddev share`, hostnames | [debugging-sharing.md](references/debugging-sharing.md) |
| Something is broken: ports, router, TLS, disk, DNS, Mutagen, CI | [troubleshooting.md](references/troubleshooting.md) |

## Everyday commands

| Task | Command |
|---|---|
| Start, stop, restart, everything off | `ddev start`, `ddev stop`, `ddev restart`, `ddev poweroff` |
| What is running and where | `ddev describe`, `ddev list`, `ddev launch` |
| Shell, one-off command | `ddev ssh`, `ddev exec <cmd>` |
| Logs | `ddev logs`, `ddev logs -s db`, `ddev logs -f` |
| Database in and out | `ddev import-db --file=x.sql.gz`, `ddev export-db --file=x.sql.gz` |
| Snapshot and restore | `ddev snapshot --name=x`, `ddev snapshot restore --latest` |
| Data from hosting | `ddev pull <provider>` (`--skip-files`, `--skip-db`, `-y`) |
| Xdebug, profiler | `ddev xdebug on` (`off`, `status`), `ddev xhgui on`, `ddev xhgui launch` |
| Mail catcher | `ddev mailpit` |
| Add-ons | `ddev add-on get <owner>/<repo>`, `ddev add-on list --installed`, `ddev add-on update` |
| Effective config, custom files | `ddev utility configyaml --full-yaml`, `ddev utility check-custom-config` |
| Health checks | `ddev utility diagnose`, `port-diagnose`, `tls-diagnose`, `mutagen-diagnose`, `xdebug-diagnose` |
| Rebuild images | `ddev start --no-cache`, `ddev utility rebuild` |

## Scripts and assets

| Resource | Use |
|---|---|
| `scripts/audit-ddev-config.py [DIR] [--json] [--ignore CHECK]` | Read-only audit of `.ddev/`. Checks: `php-unpinned`, `php-out-of-range`, `php-eol`, `db-unpinned`, `node-eol`, `composer-v1`, `obsolete-key`, `perf-mode-committed`, `router-ports-committed`, `xdebug-committed`, `upload-dir-misplaced`, `upload-dir-outside`, `shadowed-command`, `crlf-command`, `ssh-agent-forwarded`, `provider-push`, `committed-secret`. Exit 0 clean, 10 findings, 3 no `.ddev/config.yaml`, 4 unreadable config, 2 usage. Never prints a secret value |
| `scripts/check-ddev-facts.py --offline` | After editing facts or prose: `assets/ddev-facts.json` vs this skill's text |
| `scripts/check-ddev-facts.py --live` | Weekly: newest DDEV release, docs defaults, built-in commands, PHP/Node.js end-of-life floors. Exit 7 = a source was unreachable (advisory) |
| `scripts/run-python.sh` | Launches either script with the first real Python 3.8+ (`python3`, `python`, `py`) |
| `assets/ddev-facts.json` | The facts both scripts share - bump values, prose and the "Versions verified" note together |
| [assets/sanitized-pull.yaml.example](assets/sanitized-pull.yaml.example) | Pull-only provider recipe for a sanitised dump: no push stanzas, files off by default |

## Boundaries

| Topic | Owner |
|---|---|
| Craft on DDEV: `ddev craft`, `.ddev/.env.web` `CRAFT_*` vars, Craft versions to pin, queue, asset `upload_dirs` | craftcms-ops (`references/ddev.md`) |
| Local-versus-production drift as a security problem: php.ini differences, devMode, keys, mail, `ddev share` exposure, personal data | security-ops (`references/ddev-config-drift.md`) |
| craft-vite and Vite HMR config behind DDEV (port in four places, CORS, allowed hosts) | frontend-upgrade-ops (`references/craft-vite-twig.md`) |
| Compose syntax for a hand-written extra service; Dockerfiles generally | docker-ops |
| Page speed of the site itself | web-perf-ops |

Never write a real-looking project hostname in examples: say "the project URL from
`ddev describe`".

## Sources

DDEV docs (docs.ddev.com, source `docs/content/users/` at tag v1.25.4), DDEV release
notes v1.25.0-v1.25.4, DDEV source (`pkg/ddevapp/config.go`, `upload_dirs.go`,
`craftcms.go`, `cmd/ddev/cmd/commands.go`), the add-on registry (addons.ddev.com) and
endoflife.date - all read 2026-10-05. DDEV publishes no agent skill for its users; its
own repository's `AGENTS.md` and `.claude/` serve people contributing to DDEV.
