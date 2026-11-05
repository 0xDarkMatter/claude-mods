---
name: boat-ops
description: "Run work on boat.dev cloud sandboxes (ephemeral Linux VMs, bx_ ids) without leaking boxes, losing work or credentials: create and size a box, exec or ssh, copy files in and out, delete and confirm the 404. Covers boat as a fleetflow remote-lane host, as a one-time GitHub Actions runner with fallback to GitHub's runner, heavy-job offload, Docker and DDEV on a box, web tools on lanes, cost and start limits, and what a box can reach. Triggers: boat, boat.dev, boat new, boat exec, bx_, cloud sandbox, remote lane, offload to boat, boat CI runner, JIT runner."
license: MIT
metadata:
  author: claude-mods
  related-skills: "fleet-ops, ci-cd-ops, docker-ops, ddev-ops, supply-chain-defense"
---

# boat-ops: ephemeral boat.dev boxes as lanes, runners and offload

A boat box is a full Ubuntu VM you rent by the second, drive with the `boat` CLI or the
REST API (`https://boat.dev/api/v1`), and throw away. It is the right tool when the
local machine is short of CPU or memory, when a lane or CI job should run on clean
Linux, or when the work must not touch the desk. Facts verified 2026-10-27 against
boat's docs and `boat help`; `scripts/check-boat-facts.py` re-checks them.

## Hard rules (each one cost something to learn)

1. **`--no-update` on every `boat` call.** The CLI updates itself, at most every 6 hours,
   after a command ends [docs: cli-reference]. That silently breaks a 7-day
   supply-chain cooldown and changes a benchmark mid-run. Never run `boat self-update`.
2. **Create with `--no-env --no-snapshots --no-monitoring`** unless you need otherwise.
   `--no-env` keeps the account's stored secrets out of the box; `--no-snapshots` means
   nothing survives the box (a stop erases it); `--no-monitoring` means boat keeps no
   command output. Without it boat keeps command history for 90 days [docs:
   data-retention].
3. **The TTL is a data-loss trap.** Auto-stop defaults to 1 hour [docs: limits], and exec
   and SSH do not extend it [docs: cli-reference]. On a `--no-snapshots` box auto-stop
   erases everything. Set `--ttl` above the whole job plus fetch-back, or
   `boat extend <id> --ttl <s>`, which SETS the time left from now; it does not add.
   Read `boat info <id> --json` first (`archiveAfter` is the live expiry) so you never
   shorten a shared box [driver].
4. **Delete what you created, and confirm it.** `boat delete <id> --yes`, then confirm:
   `info` answers `not_found` AND `boat list --all` no longer shows it (plain `boat list`
   shows only running boxes). `"<skill-dir>/scripts/confirm-gone.sh" <id>` does both.
   Never delete, extend or exec on a box you did not create unless the user names it:
   other sessions' boxes share the account.
5. **Check which account the CLI is on before any work.** `boat status` and `boat org`
   show the account and the wallet that new boxes bill. A CLI signed in to another
   company's account looks identical, and nothing on the box says whose it is [field].
   To work for a second company, do not switch the login: put that company's key in
   `BOAT_API_KEY` for the job's process, which overrides the stored login for that process
   only. See [security-model](references/security-model.md#policy-and-accounts).
6. **Credentials never travel in argv.** Other users on a host can read process
   arguments. Pass a key on stdin (`boat login --key-stdin`, or `boat ssh` stdin into
   env), or as an API header from a file; never as a flag value or in an exec string.
7. **A box is readable by everything on it.** The box user has passwordless sudo, and
   every `boat exec` child inherits `CAP_DAC_READ_SEARCH` from boat's agent, so even a
   `chmod 000` directory is readable [field, measured]. Never leave a credential file on
   a box; never put production data on one. See [security-model](references/security-model.md).

## Lifecycle at a glance

```bash
B="boat --no-update"
$B new --type default --ttl 3600 --no-env --no-snapshots --no-monitoring \
       --name ci-myrepo-pr12-ab12cd3 --json > new.jsonl     # JSONL: created, state, ready
id="$(jq -rs 'map(select(.event=="created"))[0].id' new.jsonl | tr -d '\r')"
$B exec "$id" --json --timeout 120 -- bash -c 'uname -a'      # waits; 600 s max
$B exec "$id" --detach -- bash -c 'make test > out.log 2>&1'  # long jobs: --status/--attach/--kill <pid>
$B ssh "$id" 'cat > in.tar' < in.tar                          # ssh forwards stdin; exec does not
$B usage "$id" --json                                         # dollars, seconds, billingMultiplier
$B delete "$id" --yes --json
bash "<skill-dir>/scripts/confirm-gone.sh" "$id"              # exit 0 = gone, 10 = still there
```

- **One job end to end:** `boat --no-update run --type default --push . -- <cmd>` creates,
  copies the tracked files in, runs, prints the cost, deletes, and exits with the
  command's code [cli].
- **Fail fast:** `--fail-fast` creates only if a machine is ready now; it answers in about
  1.5 s and costs nothing when none is [cli].
- **Seed a box at create:** `--file SANDBOX_PATH=LOCAL_FILE` (text, 256KB in total) and
  `--setup-file` (a 64KB script, runs in the background; watch `setupStatus` in `info`).
- **Copy in and out:** see [box-lifecycle](references/box-lifecycle.md). Short version:
  small files go over `ssh`/`exec` with a sha256 check; `scp` costs 10-15 s fixed per
  call; `boat push` sends only git-tracked or unignored files.

Full lifecycle, every CLI fact the docs do not spell out, and copy recipes:
[references/box-lifecycle.md](references/box-lifecycle.md).

## Naming

- Box ids match `bx_[a-z0-9]+`; validate before splicing one into a command.
- `--name` takes up to 120 characters [cli]. Make it say what and whose: CI boxes as
  `ci-<repo>-pr<N>-<sha7>-run<run_id>-<attempt>` (or `ci-<repo>-manual-...`), so a sweeper
  can find leftovers by the `ci-` prefix and a human can read the dashboard.
- **fleetflow lane ids: 10 characters or fewer.** A remote lane's TMPDIR is
  `$HOME/ff/cache/<repo-slug>/<run>/<id>`. At about 76 characters every Claude Code Bash
  call fails ("Failed to create bridge sockets"); 68-74 worked [field, measured; cause
  inferred: the 108-byte AF_UNIX socket path limit]. Respawn under a shorter id; a retry
  fails the same way.
- A one-time CI runner's label must be unique per run and attempt
  (`boat-<run_id>-<attempt>`): a generic label can be claimed by another repo's job in the
  same runner group [field].

## Size and cost in one table

| Size | vCPU / RAM / disk | $/hour [docs: pricing] | Use for |
|---|---|---|---|
| `small` | 2 / 4 GB / 12 GB | $0.018 | probes, light scripts |
| `default` | 4 / 8 GB / 50 GB | $0.036 | CI gates, Docker builds, agent lanes |
| `large` | 8 / 16 GB / 125 GB | $0.072 | heavy builds, many containers |
| `xlarge` | 16 / 32 GB / 251 GB | $0.200 | needs the $100 plan or higher |

Billed per second while running; no GPU on any size. The $20 plan includes 555 h of
`default`, 100 at once and 12 / 60 / 200 starts per minute / hour / day; seats multiply
the limits [docs]. Starts are the limit you hit first: pace bulk creates under 12 a
minute. Measured costs (a CI gate about $0.0033, a Docker build under $0.001) and the
limits and error codes: [references/cost-and-limits.md](references/cost-and-limits.md).

## What to use a box for

| Use | Start here |
|---|---|
| A fleetflow lane on a remote box (`--host boat:new`), lanes per box, Codex on a box | [references/fleetflow-lanes.md](references/fleetflow-lanes.md) |
| Offload a heavy gate, render or test fan-out from a strained machine | [references/fleetflow-lanes.md](references/fleetflow-lanes.md#heavy-job-offload) |
| A one-time GitHub Actions runner, with fallback to GitHub's runner | [references/ci-runner.md](references/ci-runner.md) |
| Docker builds or DDEV on a box | [references/docker-ddev.md](references/docker-ddev.md) |
| WebSearch/WebFetch missing on a remote lane | [references/fleetflow-lanes.md](references/fleetflow-lanes.md#web-tools-on-lanes) |
| Can this code or data go on a box? What can a box reach? | [references/security-model.md](references/security-model.md) |

## Security model in five lines

- Each box is its own VM; boxes reach each other only over the network. Inside one, the
  user is root (passwordless sudo) and containers share its kernel [docs: security].
- Network: outbound open to the internet; inbound refused except SSH and ports you
  publish with `boat host` (a token URL is a password; `--public` is open to anyone).
- Org boxes are visible to every member of the org that pays for them [docs].
- Data sits on machines in Germany, Finland and France, and snapshot copies can be stored
  outside the EU [docs]. Placement is not selectable. Check this against any residency
  clause before code goes on a box.
- Ephemeral is the whole argument for putting private or client code on a box: ship a
  credential-free git bundle or archive, keep production databases and their dumps off,
  destroy the box and confirm it. Policy that is still open is in the reference.

## Landmines

| Landmine | What happens | Do instead |
|---|---|---|
| `boat new --json` prints JSONL | `jq -r .id` yields three lines; a delete given that string fails and the box leaks [driver] | `jq -rs 'map(select(.event=="created"))[0].id'` |
| `boat exec` does not forward stdin | data piped in never arrives | `boat ssh <id> '<cmd>' < file` |
| `exec --timeout` above 600 s (or 0) | output switches to a live stream; JSON callers break [cli] | keep waits at 600 s or less; `--detach` for long jobs |
| Waiting-command output cap | 8 MiB per stream [docs: limits]; fleetflow saw truncation between 3.5 and 13.4 MB | download big files in chunks, or over `ssh` |
| Non-zero remote exit | the CLI exits 1 with a JSON error line, hiding the real code [driver] | read `exitCode` from `--json`, or echo a sentinel like `__rc=$?` to stderr |
| `boat scp` with a Windows path | any path containing `X:` reads as a sandbox id [driver] | `cd` to the file's folder and pass a bare name |
| Git Bash path rewriting | args that look like POSIX paths are rewritten before boat.exe sees them | `MSYS_NO_PATHCONV=1` on boat calls |
| Windows `jq.exe` | prints CRLF, and cannot open a `<(...)` `/proc` path [driver] | strip `\r`; write temp files |
| `git archive` on Windows | hook scripts arrive with CRLF | `git -c core.autocrlf=false archive ...` |
| `CAP_DAC_READ_SEARCH` on exec children | `chmod 000` still readable: permission tests fail, Codex's bwrap refuses to start [field] | `setpriv --inh-caps=-all --ambient-caps=-all --` (see references) |
| Repo denies WebFetch/WebSearch by bare name | the tool vanishes from a lane even when allowed [field] | fleetflow's refusal or `FLEETFLOW_REMOTE_WEB_LIFT=1` |
| Long lane ids | Bash sandbox fails to start on the box | ids of 10 characters or fewer |
| Switching company with `boat login` | rewrites the one machine-wide login under every shell and session; the config path is fixed (Windows `%AppData%\ascii\boat\config.json`), a redirected `APPDATA` does not move it, and there is no config-path variable [field] | `BOAT_API_KEY` in the job's environment |
| A new API key made on the dashboard | scoped to a personal account despite the org banner; `org` in a create gave 403 `not_org_member` [field] | `GET /api/v1/orgs` once before wiring a key into CI |
| Auto mode | refuses agent steps that put a credential on a third-party VM [driver] | a permission rule for the exact command, or leave auto mode |
| Parallel workers on a fresh box | race on a first model or package download [field] | one-worker warm-up pass first |

## Scripts

- **`check-boat-facts.py`** - the staleness verifier (SKILL-RESOURCE-PROTOCOL section 7)
  for `assets/boat-facts.json`, the rates, limits, retention and security facts and the
  CLI flags this skill relies on.
  - `python "<skill-dir>/scripts/check-boat-facts.py" --offline` (PR CI): the prose still
    states every catalogued fact and flag, and SKILL.md's "Facts verified" date matches.
  - `python "<skill-dir>/scripts/check-boat-facts.py" --live` (weekly): each fact against
    `https://docs.boat.dev/<page>.md`, and each flag against the docs CLI reference and,
    if a boat CLI is installed (`BOAT_BIN` or `boat` on PATH), `boat --no-update help`.
    Exit 10 = drift, 7 = a page unreachable or reshaped (advisory), 0 = current.
- **`confirm-gone.sh`** - read-only deletion check: polls `info` until `not_found`, then
  checks `list --all`. It never deletes. `bash "<skill-dir>/scripts/confirm-gone.sh"
  --timeout 90 bx_aaaa bx_bbbb` prints `id<TAB>gone|present`; exit 0 all gone, 10 some
  still there, 7 boat unreachable, 5 no boat CLI or jq.

## Related skills

- `fleet-ops` lands the branches remote lanes bring home; fleetflow (its own repo) owns
  the remote-lane runtime described in [fleetflow-lanes](references/fleetflow-lanes.md).
- `ci-cd-ops` for GitHub Actions in general; this skill only covers the boat runner.
- `docker-ops` and `ddev-ops` for the tools themselves; this skill covers running them on
  a box.
- `supply-chain-defense` for the 7-day cooldown that `--no-update` protects.

## Sources

Every fact above carries its source tag:
- **[docs]** boat's docs, read 2026-10-27 (`pricing`, `limits`, `data-retention`,
  `security`, `cli-reference`, `llms.txt`).
- **[cli]** `boat help <command>`, 2026-10-27.
- **[driver]** fleetflow's host driver `scripts/hosts/boat.sh` and its project boat-ops
  skill (2026-10-22 to 10-25).
- **[bench]** fleetflow's sandbox-bench runs, 2026-10-22.
- **[field]** field reports from 2026-10-23 to 10-27, generalised: fleetflow's Codex
  sandbox reports, a CI runner trial and benchmark on two private repos, build-only Docker
  benchmarks of two client sites, a web-tools lane fix, DDEV on a box, and heavy-job
  offload; and a per-process `BOAT_API_KEY` test on 2026-11-05.
