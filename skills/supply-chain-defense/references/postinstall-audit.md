# Post-install behavioural audit — closing the on-disk gap

`scripts/postinstall-audit.py`: the after-the-fact sweep of what already landed on disk.

## Contents

1. [The gap it closes](#the-gap-it-closes)
2. [What it flags](#what-it-flags)
3. [Incremental cache (daily-runnable)](#incremental-cache-daily-runnable)
4. [Exit codes](#exit-codes)
5. [--deep (GuardDog confirmation)](#--deep-guarddog-confirmation)
6. [--live (registry takedown check)](#--live-registry-takedown-check)
7. [Existing-tool evaluation (tool-first)](#existing-tool-evaluation-tool-first)
8. [Scheduling — run it daily](#scheduling--run-it-daily)
9. [When a finding fires](#when-a-finding-fires)

## The gap it closes

The pre-install controls in this skill (the `socket` wrapper, `preinstall-check.sh`
cooldown, the install-scan hook) all act **before** a package executes. They are the
right primary defence, but each has a miss case:

- The cooldown is **fooled by tag-rewrite** attacks (Laravel-Lang): the poisoned
  artifact carries an *aged* version number, so "released >7 days ago" passes.
- The `socket` wrapper only covers installs **routed through it** — a manual
  `npm install`, a CI step, or an editor's "install dependencies" prompt bypasses it.
- Behavioural scanners can miss a version **published seconds ago** that the engine
  hasn't analysed yet.

When any of those misses, the malware is already in `node_modules` / `site-packages`.
`scripts/postinstall-audit.py` is the **after-the-fact** sweep for exactly that state —
it scans what actually landed on disk for the behaviours the 2026 worms exhibit, rather
than asking a registry whether a name is known-bad.

## What it flags

Per package, grouped so a single weak signal never fires alone (real `node_modules`
trees are full of `eval` and base64 — see the false-positive note below):

| Finding | Severity | Signal |
|---|---|---|
| `lifecycle-shell` | high | a `preinstall`/`install`/`postinstall`/`prepare` script that spawns a shell or downloader (`curl … \| sh`, `powershell iwr`, `node -e`, `certutil`, `/dev/tcp`) |
| `cred-exfil` | high | a credential-path read (`.npmrc`, `.aws/credentials`, `.claude/`, browser `Login Data`, SSH keys) **+** an exfil endpoint in the same package |
| `env-exfil` | high | `JSON.stringify(process.env)` / `dict(os.environ)` **+** an exfil endpoint |
| `registry-unpublished` | high | (`--live`) a flagged npm version the registry no longer serves — a takedown IOC |
| `obfuscation` | medium | `_0x…` hex-identifier obfuscation, long `\x..` runs, `marshal.loads`, `zlib.decompress(base64…)` in **non-minified** source |
| `persistence-write` | medium | references to agent/editor settings (`.claude/settings`, `mcpServers`, `…\Run`) paired with a payload marker |
| `modified-after-install` | medium | newest file mtime postdates the `node_modules/.package-lock.json` install marker by >2 min — tamper after extraction |
| `lifecycle-present` | low | a lifecycle script on a package not on the known-benign allowlist (informational) |
| `cred-path-reference` | low | credential paths referenced without a paired network sink |
| `eval-base64` | low | `eval`/`Function` **and** base64 decode co-occurring in one small non-minified file |

"Exfil endpoint" = `webhook.site`, Discord/Telegram webhooks, paste sites,
`transfer.sh`, OAST/interactsh collaborators, or a raw-IP URL.

Default `--min-severity medium` reports the high/medium tiers and stays silent on the
low informational ones. Drop to `--min-severity low` (or use `--json`) to see everything.

### The false-positive lesson (why combos, not singletons)

An earlier cut flagged `eval` + base64 as **high**. On a real tree that lit up
`three.js`, `vite`, and `source-map-js` — all legitimate: bundlers, source-map VLQ
codecs, and wasm loaders use both constantly. Singleton behavioural greps do not work on
`node_modules`. The scanner therefore requires a **two-signal combo** for every
high/medium finding (credential-read **and** network sink; env-harvest **and** network
sink), and demotes the eval+base64 co-occurrence to a sub-threshold `low`. This mirrors
the `scan-extensions.sh` lesson recorded in the threat model: grep heuristics on minified
bundles produce false-cleans and false-alarms in equal measure — the value is in
co-occurrence and recency, not any one pattern.

## Incremental cache (daily-runnable)

Every package is fingerprinted by `(name@version, file-count, total-size, max-mtime)`.
A re-run reads the cache (`%LOCALAPPDATA%\supply-chain-defense\postinstall-audit-cache.json`
on Windows, `$XDG_CACHE_HOME` / `~/.cache` elsewhere) and **only rescans packages whose
fingerprint changed**. On a stable tree the second run is near-instant. `--no-cache`
forces a full scan; `--cache PATH` points at an alternate file (used by the test suite).

The cache stores the *findings*, not just a clean/dirty bit, so a cached hit still reports
its findings — the cache speeds the scan, it does not hide results.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | clean — no findings at/above `--min-severity` |
| 2 | usage error (bad flag, no existing root) |
| 3 | no root directory exists |
| 5 | `--deep` requested but GuardDog/semgrep absent → **loud skip, heuristics still ran** (never a silent false-clean) |
| 7 | `--live` only: the registry was unreachable (advisory, not a finding) |
| 10 | one or more findings at/above `--min-severity` |

`7` is deliberately distinct from `10`: a network blip during `--live` must never read as
"package is bad". This is the same staleness-verifier discipline as §7 of
`docs/SKILL-RESOURCE-PROTOCOL.md`.

## --deep (GuardDog confirmation)

`--deep` runs GuardDog's AST/semgrep rules against each *flagged* package to corroborate
the heuristic verdict. It is **on-demand**: if `guarddog`+`semgrep` aren't on PATH the
script logs a loud one-line skip and the recommended install (`uv tool install guarddog
semgrep`) rather than pretending it ran. On Windows the script sets `PYTHONUTF8=1` for the
GuardDog subprocess — without it GuardDog silently exits "0 indicators" (a false-clean,
the gotcha recorded in `references/tooling-landscape.md`).

## --live (registry takedown check)

`--live` asks `registry.npmjs.org` whether each *flagged* npm `name@version` still exists.
A `404` means the version was unpublished — a strong post-compromise IOC (the registry
took it down). A network failure never fakes that finding: the record gets
`registry: "unavailable"` (and a `[live] registry: unavailable` line in text mode).

**Exit precedence.** `--live` only checks packages that are already flagged, so a run
that reaches the registry has findings and exits `10` whatever the registry says - an
outage must not hide them, and there is no separate `7`. Read the outage from the
envelope instead: `meta.live` is `"off"` (no `--live`), `"complete"` (every check
answered) or `"unavailable"`, with the unchecked `name@version`s in
`meta.live_unchecked`; stderr carries an `ERROR: --live registry check unavailable`
line naming them.

## Existing-tool evaluation (tool-first)

Per the user's tool-first rule, this was weighed against off-the-shelf options before
building:

| Tool | Fit for the on-disk post-install gap | Verdict |
|---|---|---|
| **GuardDog** (`guarddog npm scan <dir>`) | Strong AST/semgrep behavioural rules, the gold standard for *one* package | **Integrated, not replaced** — `--deep` shells out to it for confirmation. It has no incremental cache, no whole-tree sweep, no tamper/mtime check, and on Windows silently false-cleans without `PYTHONUTF8=1`; this script provides the cheap always-on layer and calls GuardDog for depth. |
| **OSV-Scanner** | Excellent CVE/advisory breadth against lockfiles | Wrong layer — advisory-driven, the exact gap this skill exists to cover. Complementary (run both), not a substitute for behaviour. |
| **Socket** | Best-in-class behavioural scoring | Pre-install / registry-side; needs the package queried through Socket. This covers what's *already unpacked locally*, offline, no account. |
| **Sandworm / lockfile-lint / npq** | Pre-install gates (audit, lockfile host validation, install prompts) | All pre-install; none scan unpacked on-disk content after the fact. |

The conclusion: nothing battle-tested does *incremental, offline, whole-tree, behavioural*
post-install scanning with tamper detection. GuardDog is the closest and is wired in as the
`--deep` confirmation engine rather than reimplemented.

## Scheduling — run it daily

### Windows Task Scheduler

```powershell
# First of python3/python/py that really runs 3.8+ - the PowerShell twin of
# scripts/run-python.sh. Get-Command alone can return the WindowsApps Store alias,
# which exits without running anything, so the task would "succeed" doing nothing.
$py = $null
foreach ($c in 'python3', 'python', 'py') {
    $cmd = Get-Command $c -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { continue }
    & $cmd.Source -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' 2>$null
    if ($LASTEXITCODE -eq 0) { $py = $cmd.Source; break }
}
if (-not $py) { throw 'No Python 3.8+ found (tried python3, python, py)' }
$arg = '"C:\Users\<you>\.claude\skills\supply-chain-defense\scripts\postinstall-audit.py"' +
       ' --root D:/code --root D:/lab' +
       ' --json'
$action  = New-ScheduledTaskAction -Execute $py -Argument $arg `
            -WorkingDirectory "$env:USERPROFILE"
$trigger = New-ScheduledTaskTrigger -Daily -At 9am
Register-ScheduledTask -TaskName "supply-chain postinstall-audit" `
  -Action $action -Trigger $trigger -Description "Daily on-disk behavioural dep scan"
```

The cache makes the daily run cheap; redirect `--json` stdout to a dated log and alert on
exit `10`.

### Claude Code cron (`/schedule`)

A scheduled cloud/local agent can run `postinstall-audit.py --json --findings-only` on the
active project roots and surface exit `10` as an issue. The script's stable `--json`
envelope (`{data:{findings,packages}, meta:{count,…}}`) is built for that consumption.

## When a finding fires

Treat a high finding as an incident, in the order the threat model prescribes:

1. **Isolate** — don't run the project; the payload executes on `node`/`python` invocation.
2. **Identify** — `--json` gives the exact file and package path; read the flagged file.
3. **Rotate** — if it read credential paths, assume they leaked; rotate every reachable token.
4. **Confirm + remove** — `--deep` for a GuardDog second opinion, `exposure-check.py` to see
   whether the same package is on other machines, then remove and reinstall from a clean,
   cooldown-aged version.
