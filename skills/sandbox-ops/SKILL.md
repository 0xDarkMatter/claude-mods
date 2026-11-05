---
name: sandbox-ops
description: "Run work on hosted cloud sandboxes without leaking boxes, losing work or credentials: boat.dev (boat, boat new, boat exec, bx_), E2B, Modal Sandboxes, Vercel Sandbox, Daytona, Fly Machines. Create and size a box, exec or ssh, copy files in and out, set the lifetime, delete and confirm it is gone, one API key per process. Covers remote agent lanes (fleetflow), one-time CI runners, heavy-job offload, Docker or DDEV on a box, residency. (Formerly boat-ops.) Not for writing @cloudflare/sandbox code: use sandbox-stable or sandbox-next."
license: MIT
metadata:
  author: claude-mods
  related-skills: "fleet-ops, ci-cd-ops, docker-ops, ddev-ops, supply-chain-defense"
---

# sandbox-ops: hosted cloud sandboxes (boat.dev in depth)

A hosted sandbox is a Linux box you rent by the second, drive from a CLI or SDK, and
throw away. It is the right tool when the local machine is short of CPU or memory, when
a lane or CI job should run on clean Linux, or when the work must not touch the desk.
boat.dev is the provider in production use and gets the full profile (`references/boat-*.md`);
E2B, Modal, Vercel Sandbox, Daytona and Fly Machines get one card each. boat Facts
verified 2026-10-27 against its docs and `boat help`; each card states its own date, and
`scripts/check-sandbox-facts.py` re-checks them.

## Hard rules, any provider

1. **Set a lifetime above the job, and know what the end does.** Every provider has a
   default that ends a 1-4 h headless job: 5 min on E2B, Modal and Vercel, 15 min idle
   on Daytona, 1 h on boat, restart-forever on Fly. Know whether it kills, stops, pauses
   or erases. Table: [ttl-traps](references/ttl-traps.md).
2. **Delete only boxes you created, then confirm with two reads in the same scope** (same
   account, org and key as the create; from another scope a live box can look missing).
   `"<skill-dir>/scripts/confirm-gone.sh" --provider <p> <id>` does the reads.
3. **Hunt what outlives the box:** paused sandboxes, snapshots, volumes, stopped disks.
   Several never expire and keep billing ([ttl-traps](references/ttl-traps.md#what-outlives-the-box)).
4. **One key per process; never switch the machine login; nothing in argv; no
   credentials left on the box.** Put the key in the job's environment. Daytona needs
   `DAYTONA_API_URL` set too. [credentials-and-auth](references/credentials-and-auth.md).
5. **A box is readable by everything on it.** Assume root inside; no production data,
   no long-lived secrets. [security-and-residency](references/security-and-residency.md).
6. **Pin the CLI.** Self-updating CLIs (boat) break a 7-day supply-chain cooldown and
   change behaviour mid-run.
7. **Name boxes `<who>-<what>-<MMDD-HHMM>`** (`who` from `gh api user --jq .login`, UTC
   time): the name is the only owner a shared dashboard shows
   ([boat-lifecycle](references/boat-lifecycle.md#name-every-box)).

## On boat

- **`--no-update` on every `boat` call.** The CLI updates itself, at most every 6 hours,
  after a command ends [docs: cli-reference]. Never run `boat self-update`.
- **Create with `--no-env --no-snapshots --no-monitoring`.** `--no-env` keeps the
  account's stored secrets out; with `--no-snapshots` a stop erases it; without
  `--no-monitoring` boat keeps command history for 90 days [docs: data-retention]. The
  one exception, a golden base image with no client code:
  [boat-snapshots](references/boat-snapshots.md).
- **The TTL is a data-loss trap.** Auto-stop defaults to 1 hour [docs: limits], and exec
  and SSH do not extend it [docs: cli-reference]. `boat extend <id> --ttl <s>` SETS the
  time left from now; read `archiveAfter` in `boat info <id> --json` first so you never
  shorten a shared box.
- **`boat new --json` prints JSONL:** take the id from the `created` event, never
  `jq -r .id` (three lines; the delete fails and the box leaks).
- **`boat exec` does not forward stdin:** pipe data with `boat ssh <id> '<cmd>' < file`.
- **`BOAT_API_KEY` in the job's environment, never `boat login` for a second company:**
  the login is one machine-wide file under every shell. `boat status` shows whose wallet
  a create will bill. See [boat-security](references/boat-security.md#policy-and-accounts).
- **Exec children hold `CAP_DAC_READ_SEARCH`:** even a `chmod 000` directory is readable.

```bash
B="boat --no-update"
$B new --type default --ttl 3600 --no-env --no-snapshots --no-monitoring \
       --name "$who-myrepo-$(date -u +%m%d-%H%M)" --json > new.jsonl
id="$(jq -rs 'map(select(.event=="created"))[0].id' new.jsonl | tr -d '\r')"
$B exec "$id" --json --timeout 120 -- bash -c 'uname -a'      # waits; 600 s max
$B exec "$id" --detach -- bash -c 'make test > out.log 2>&1'  # long jobs: --status/--attach/--kill <pid>
$B ssh "$id" 'cat > in.tar' < in.tar                          # ssh forwards stdin; exec does not
$B delete "$id" --yes --json
bash "<skill-dir>/scripts/confirm-gone.sh" "$id"              # exit 0 = gone, 10 = still there
```

- One job end to end: `boat --no-update run --type default --push . -- <cmd>` creates,
  copies tracked files in, runs, deletes and exits with the command's code [cli].
- `--fail-fast` creates only if a machine is ready now (about 1.5 s, free when none is);
  `--setup-file` seeds a 64KB script at create.
- Sizes `small` / `default` / `large` / `xlarge` (2 to 16 vCPU), `default` $0.036 an
  hour; starts (12 a minute on the $20 plan) are the limit you hit first. Rates, limits,
  error codes: [boat-cost-and-limits](references/boat-cost-and-limits.md). Copy recipes,
  timings, Windows-host traps: [boat-lifecycle](references/boat-lifecycle.md).

## Providers

| Provider | Pick it for | Key variable | Default end | Worst trap | Card |
|---|---|---|---|---|---|
| boat.dev | cheapest by far; fleetflow driver exists | `BOAT_API_KEY` | auto-stop 1 h | a stop with snapshots off erases the box | `boat-*` refs |
| E2B | agent template, pause/resume with memory | `E2B_API_KEY` | kill at 5 min | paused sandboxes never expire | [e2b](references/e2b.md) |
| Modal | `au` region, env overrides the profile | `MODAL_TOKEN_ID` + `_SECRET` | 5 min | no SSH; region multiplier | [modal](references/modal.md) |
| Vercel Sandbox | `syd1`, credential injection | `VERCEL_TOKEN` (SDK) | 5 min, then snapshot | stop-snapshots pile up | [vercel](references/vercel.md) |
| Daytona | native SSH, Claude Code preinstalled | `DAYTONA_API_KEY` + `_URL` | stop at 15 min idle | 10 GB disk; key ignored without URL | [daytona](references/daytona.md) |
| Fly Machines | cheap Australian VM, plain SSH | `FLY_API_TOKEN` | restart `always` | rootfs and volumes bill when stopped | [fly](references/fly.md) |

Writing code against Cloudflare's `@cloudflare/sandbox` SDK is a platform build, not a
hosted box: use `sandbox-stable` or `sandbox-next`. The verbs every provider must offer,
side by side: [lifecycle-contract](references/lifecycle-contract.md).

## What to use a box for

| Use | Start here |
|---|---|
| A fleetflow lane on a remote boat box, lanes per box, Codex on a box | [boat-fleetflow-lanes](references/boat-fleetflow-lanes.md) |
| Offload a heavy gate, render or test fan-out | [boat-fleetflow-lanes](references/boat-fleetflow-lanes.md#heavy-job-offload) |
| A one-time GitHub Actions runner, with fallback to GitHub's runner | [boat-ci-runner](references/boat-ci-runner.md) |
| Docker builds or DDEV on a box | [boat-docker-ddev](references/boat-docker-ddev.md) |
| WebSearch/WebFetch missing on a remote lane | [boat-fleetflow-lanes](references/boat-fleetflow-lanes.md#web-tools-on-lanes) |
| Can this code or data go on a box? Where does it run? | [security-and-residency](references/security-and-residency.md), [boat-security](references/boat-security.md) |
| A lane or runner on another provider | its card, then [lifecycle-contract](references/lifecycle-contract.md) |

## Landmines

| Landmine | What happens | Do instead |
|---|---|---|
| A provider's default timeout | the job dies at 5-15 min, or a Fly job restarts forever | set the lifetime at create; read it back |
| Confirming from another account or org | a live box looks gone | confirm in the create's scope |
| A paused, stopped or snapshotted leftover | bills for weeks; E2B paused boxes never expire | list them after every run |
| A key in a flag (`--token`, `--api-key`) | readable in the process list and shell history | the provider's env variable |
| `DAYTONA_API_KEY` alone | the CLI runs under the saved profile's account | set `DAYTONA_API_URL` too |
| `exec --timeout` above 600 s (or 0) on boat | output switches to a live stream; JSON callers break [cli] | 600 s or less; `--detach` for long jobs |
| boat waiting-command output cap | 8 MiB per stream [docs: limits] | chunk big downloads, or use `ssh` |
| boat non-zero remote exit | the CLI exits 1, hiding the real code [driver] | read `exitCode` from `--json`, or a `__rc=$?` sentinel |
| boat `CAP_DAC_READ_SEARCH` | permission tests fail; Codex's bwrap refuses to start [field] | `setpriv --inh-caps=-all --ambient-caps=-all --` |
| Repo denies WebFetch/WebSearch by bare name | the tool vanishes from a lane [field] | fleetflow's refusal or `FLEETFLOW_REMOTE_WEB_LIFT=1` |
| fleetflow lane ids over 10 characters | the Bash sandbox fails to start on the box (socket path limit) | ids of 10 characters or fewer |
| A boat key made on the dashboard | scoped to a personal account; an `org` create gave 403 `not_org_member` [field] | `GET /api/v1/orgs` once before wiring a key into CI |
| boat REST delete without `X-Ascii-Confirm-Delete` | 409, and the box keeps billing [field] | send the header; retry 409, 429, 5xx |
| An outage during cleanup | a delete lost to it is never re-sent [field] | retry with backoff; an outage ends in exit 7, never a pass |
| Auto mode | refuses steps that put a credential on a third-party VM [driver] | a permission rule for the exact command |
| Parallel workers on a fresh box | race on a first model or package download [field] | a one-worker warm-up pass first |

Windows-host traps (`scp` paths, Git Bash rewriting, `jq.exe` CRLF) are in
[boat-lifecycle](references/boat-lifecycle.md#driving-boat-from-a-windows-host).

## Scripts

- **`check-sandbox-facts.py --provider boat|e2b|modal|vercel|daytona|fly|all`**: the
  staleness verifier (SKILL-RESOURCE-PROTOCOL section 7) for `assets/facts-boat.json` and
  `assets/facts-providers.json`. `--offline` (PR CI): the prose still states every fact
  and flag, and each verified date matches. `--live` (weekly): each fact against its docs
  page, and boat's flags against `boat --no-update help` where installed. Exit 10 drift,
  7 a page unreachable or reshaped (advisory), 0 current.
- **`confirm-gone.sh [--provider boat|e2b|vercel|daytona|fly] <id>...`**: read-only.
  boat: polls `info` until `not_found`, then checks `list --all`; others: the id must be
  absent from the provider's list. Prints `id<TAB>gone|present`; exit 0 all gone, 10 some
  still there, 7 provider unreachable, 5 no CLI or jq. It never deletes.

## Related skills

- `fleet-ops` lands the branches remote lanes bring home; fleetflow (its own repo) owns
  the remote-lane runtime in [boat-fleetflow-lanes](references/boat-fleetflow-lanes.md).
- `ci-cd-ops` for GitHub Actions in general; `docker-ops` and `ddev-ops` for the tools.
- `supply-chain-defense` for the 7-day cooldown that pinning the CLI protects.
- `sandbox-stable` / `sandbox-next` (Cloudflare's) for `@cloudflare/sandbox` code.

## Sources

- **[docs]** each provider's docs: boat's read 2026-10-27, the others 2026-11-05 (URLs
  in the cards). **[cli]** `boat help <command>`, 2026-10-27.
- **[driver]** fleetflow's host driver `scripts/hosts/boat.sh`; **[bench]** its
  sandbox-bench runs, 2026-10-22.
- **[field]** field reports 2026-10-23 to 11-05: Codex sandbox reports, a CI runner
  trial, Docker benchmarks, DDEV on a box, heavy-job offload, a REST teardown review and
  a per-process `BOAT_API_KEY` test.
- **[report]** the 2026-11-05 provider research behind the cards.
