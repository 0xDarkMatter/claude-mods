---
name: ddev-ops
description: "Use when a project has a .ddev/ folder or needs one: DDEV setup on a new machine, version pinning, config.local.yaml and .ddev/.env files, database import, snapshots, ddev pull and sanitised data, slow Mutagen or WSL2 sites, add-ons (Redis, Solr, cron), commands and hooks, Vite ports, Xdebug, ddev share, port conflicts, several git worktrees at once, scripting DDEV (describe -j), disk cleanup, upgrades and troubleshooting. Audits .ddev/ for team-breaking mistakes."
license: MIT
allowed-tools: "Read Edit Write Bash Glob Grep"
metadata:
  author: claude-mods
  related-skills: "craftcms-ops, security-ops, frontend-upgrade-ops, docker-ops, web-perf-ops, package-manager-ops"
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

   Exit 10 means findings, sorted high to low (severity, check, file, detail); 0 means
   clean. `--ignore <check>` documents a deliberate exception.
3. **Run everything through DDEV** - `ddev composer`, `ddev php`, `ddev npm`,
   `ddev exec` - so commands use the container's PHP and Node, not the host's.
4. **Snapshot before anything risky**, with a unique name:
   `ddev snapshot --name=before-<task>-$(date +%Y%m%d%H%M%S)`. A reused name saves
   nothing and still exits 0.
5. **Ask before destroying data** (Hard rule 11).

## Hard rules

Rules 2, 3, 4, 6, 8 and 12 were each seen in a 2026-10-05 read of 36 DDEV-based agency
repositories; the rest are quiet failures DDEV's own docs and source describe.

1. **Pin `php_version` and `database` to production.** Unpinned projects follow DDEV's
   defaults, which move: v1.25.0 switched PHP 8.3 to 8.4 and MariaDB 10.11 to 11.8.
   Also pin `nodejs_version` and `composer_version: "2"`.
2. **Per-developer settings never go in `config.yaml`.**
   - That means `performance_mode`, `router_http_port`/`router_https_port`,
     `xdebug_enabled: true`, `bind_all_interfaces` and `host_db_port`.
   - They belong in `.ddev/config.local.yaml` or `ddev config global`.
   - Project values beat global ones, so a committed value pins every teammate.
   - Git ignores the `.local` files only after DDEV has run in that checkout, because
     its `.ddev/.gitignore` isn't committed. Add `.ddev/config*.local.y*ml` and
     `.ddev/.env*.local` to the project root's `.gitignore`.
3. **Retired keys do nothing.** DDEV loads config non-strictly:
   `mutagen_enabled: false` and `nfs_mount_enabled` are ignored, not obeyed.
4. **`upload_dirs` resolve from the docroot.** With `docroot: web`, `storage` means
   `web/storage`; folders beside the docroot are `../storage` and `../node_modules`.
   Setting the list replaces the type's defaults; override files append to it.
5. **No secrets in committed `.ddev/.env*` files.** Use the `.local` twin
   (`.ddev/.env.web.local`, v1.25.4+), kept out of git as rule 2 says. Commit a
   `.example` with `git add -f`, since DDEV's `.gitignore` hides `*.example`.
6. **Never forward the host SSH agent into containers.** Every process in them -
   Composer and npm scripts included - could sign with every key the agent holds. Load
   one scoped key with `ddev auth ssh -f <key>`.
7. **Pull sanitised data; never push to production.**
   - Anonymise where the data lives and pull the result. No raw production personal data
     on laptops.
   - Delete `db_push_command`/`files_push_command` from your own recipes that can reach
     production.
   - A `files_pull_command` that fetches nothing makes `ddev pull` empty the upload
     directory, and the pull still exits 0. Omit the stanza instead.
8. **Don't keep project copies of DDEV's built-in commands** (`craft`, `npm`,
   `artisan`, `wp`...). A project command shadows the built-in and freezes an old
   version. Command files must have LF endings: DDEV skips CRLF ones with only a warning.
9. **Review an add-on before installing it.** Its Bash install actions run on your
   machine. Prefer official `ddev/` add-ons and pin `--version`.
10. **On Windows, keep projects inside the WSL2 filesystem**, never under `/mnt/c`.
11. **Confirm with the user before destroying data.** These destroy data:
    - `ddev delete`, `ddev stop --remove-data`, `ddev start --reset-database`;
    - `ddev snapshot --cleanup`, `ddev clean`, `ddev push`;
    - `ddev import-db` and `ddev import-files`, which empty their target first;
    - `docker volume prune -a`, which deletes stopped projects' databases.

    `ddev poweroff` stops everyone's projects.
12. **Several checkouts need distinct project names.** A committed `name:` makes every git
    worktree claim the same project. Omit it, or override it in `config.local.yaml`.

## Driving DDEV from a script or agent

- **Never run bare `ddev`** (it opens a dashboard) **or flagless `ddev config`** (it asks
  questions). Pass `--file`/`--source` to imports and `-y` to anything that prompts.
- **Read state as JSON:** `ddev describe -j | jq -r '.raw.primary_url'` (also
  `.raw.status`, `.raw.dbinfo.published_port`); `ddev list -j`;
  `ddev launch --print-url`.
- **Single-quote `ddev exec` commands** that contain `$`, pipes or redirects, so they
  expand inside the container.
- **Exit 0 isn't always success:** a duplicate `ddev snapshot` name and
  `ddev add-on remove` leaving files behind both exit 0.

Details, the destroys-data table and worktree setup:
[automation-and-worktrees.md](references/automation-and-worktrees.md).

## Route by task

| Task | Read |
|---|---|
| Existing repo on a new machine, new project, version pinning, CI parity, Composer, what to commit, env files, upgrading DDEV | [config-and-env.md](references/config-and-env.md) |
| Scripting DDEV, JSON output, commands that destroy data, several git worktrees, renaming or moving a project | [automation-and-worktrees.md](references/automation-and-worktrees.md) |
| Import/export, snapshots, seed and reset, changing engine, `ddev pull` recipes, sanitised data | [database.md](references/database.md) |
| Slow project, Mutagen, `upload_dirs`, WSL2, choosing a Docker provider | [performance.md](references/performance.md) |
| Add-ons (Redis, search, cron), commands, hooks, daemons, nginx/Apache config, extra services, networking between projects, PHP ini, SSH keys | [extending.md](references/extending.md) |
| Node.js version, npm/pnpm/yarn, dev-server ports and daemons | [frontend-node.md](references/frontend-node.md) |
| Craft + Vite HMR not connecting (CORS, allowed hosts, the port in four places) | frontend-upgrade-ops' `references/craft-vite-twig.md` |
| Xdebug, XHGui profiling, Mailpit, `ddev share`, hostnames | [debugging-sharing.md](references/debugging-sharing.md) |
| Something is broken: Docker, ports, router, TLS, disk, DNS, Mutagen | [troubleshooting.md](references/troubleshooting.md) |

## Everyday commands

| Task | Command |
|---|---|
| Start, stop, restart, everything off | `ddev start`, `ddev stop`, `ddev restart`, `ddev poweroff` |
| What is running and where | `ddev describe` (`-j` for JSON), `ddev list`, `ddev launch` |
| Shell, one-off command | `ddev ssh`, `ddev exec <cmd>` |
| Logs | `ddev logs`, `ddev logs -s db`, `ddev logs -f` |
| Database in and out | `ddev import-db --file=x.sql.gz`, `ddev export-db --file=x.sql.gz` |
| Snapshot and restore | `ddev snapshot --name=<unique>`, `ddev snapshot restore --latest` |
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
| `scripts/audit-ddev-config.py [DIR] [--json] [--ignore CHECK]` | Read-only audit of `.ddev/`; details below the table |
| `scripts/check-ddev-facts.py --offline` | After editing facts or prose: `assets/ddev-facts.json` vs this skill's text |
| `scripts/check-ddev-facts.py --live` | Weekly: newest DDEV release, docs defaults, built-in commands, PHP/Node.js end-of-life floors. Exit 7 = a source was unreachable (advisory) |
| `scripts/run-python.sh` | Launches either script with the first real Python 3.8+ (`python3`, `python`, `py`) |
| `assets/ddev-facts.json` | The facts both scripts share - bump values, prose and the "Versions verified" note together |
| [assets/sanitized-pull.yaml.example](assets/sanitized-pull.yaml.example) | Database-only provider recipe for a sanitised dump: no files stanza, no push stanzas |

**The auditor:**
- **Checks:**
  - versions: `php-unpinned`, `php-out-of-range`, `php-eol`, `db-unpinned`, `node-eol`,
    `composer-v1`;
  - config: `obsolete-key`, `perf-mode-committed`, `router-ports-committed`,
    `xdebug-committed`, `name-in-worktree`;
  - folders and commands: `upload-dir-misplaced`, `upload-dir-outside`,
    `shadowed-command`, `crlf-command`;
  - safety: `ssh-agent-forwarded`, `provider-push`, `provider-files-noop`,
    `committed-secret`, `local-file-committed` (reads git's index, with the repo's
    `core.fsmonitor` command disabled).
- **Exit codes:** 0 clean, 10 findings, 3 no `.ddev/config.yaml`, 4 unreadable config,
  2 usage.
- **It reads config the way DDEV does:** overrides merge, lists append. It skips DDEV's
  own generated recipes and never prints a secret value.

## Boundaries

| Topic | Owner |
|---|---|
| Craft on DDEV: `ddev craft`, `.ddev/.env.web` `CRAFT_*` vars, Craft versions to pin, queue, asset `upload_dirs` | craftcms-ops (`references/ddev.md`) |
| Local-versus-production drift as a security problem: php.ini differences, devMode, keys, mail, `ddev share` exposure, personal data | security-ops (`references/ddev-config-drift.md`) |
| craft-vite and Vite HMR config behind DDEV (port in four places, CORS, allowed hosts) | frontend-upgrade-ops (`references/craft-vite-twig.md`) |
| Install commands, lockfiles, `.nvmrc`/`engines` agreeing with DDEV's Node and PHP | package-manager-ops |
| Compose syntax for a hand-written extra service; Dockerfiles generally | docker-ops |
| Page speed of the site itself | web-perf-ops |

Never write a real-looking project hostname in examples: say "the project URL from
`ddev describe`".

## Sources

- **DDEV docs:** docs.ddev.com, source `docs/content/users/` at tag v1.25.4.
- **DDEV release notes:** v1.25.0-v1.25.4.
- **DDEV source:** `pkg/ddevapp/` (`config.go`, `provider.go`, `ddevapp.go`,
  `upload_dirs.go`, `craftcms.go`), `pkg/settings/viper.go` and
  `cmd/ddev/cmd/commands.go`.
- **Also:** the add-on registry (addons.ddev.com) and endoflife.date.

Read 2026-10-05 and re-checked by an independent accuracy review on 2026-10-06. What
the references mark "Observed" was reproduced that day in throwaway projects on DDEV
v1.25.4 (Docker Desktop, WSL2). DDEV
publishes no agent skill for its users; its own repository's `AGENTS.md` and `.claude/`
serve people contributing to DDEV.
