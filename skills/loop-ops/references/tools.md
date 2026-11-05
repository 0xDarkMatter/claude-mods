# loop-ops Tools

Flags, examples, exit codes and host-specific behaviour for the six scripts SKILL.md lists, and the shipped worked example.

## Contents

- [`scripts/loop-scaffold.sh` — scaffold a loop's state spine](#scriptsloop-scaffoldsh--scaffold-a-loops-state-spine)
- [`scripts/loop-check.sh` — readiness scorer (run before you schedule)](#scriptsloop-checksh--readiness-scorer-run-before-you-schedule)
- [`scripts/loop-doctor.sh` — live preflight (will it actually run?)](#scriptsloop-doctorsh--live-preflight-will-it-actually-run)
- [`scripts/loop-estimate.py` — token/$ estimate by pattern × cadence × model (caching-aware)](#scriptsloop-estimatepy--token-estimate-by-pattern--cadence--model-caching-aware)
- [`scripts/check-pricing-sync.py` — offline drift guard (CI)](#scriptscheck-pricing-syncpy--offline-drift-guard-ci)
- [`scripts/check-native-facts.py` — native-scheduling staleness guard](#scriptscheck-native-factspy--native-scheduling-staleness-guard)
- [Worked example](#worked-example)

### `scripts/loop-scaffold.sh` — scaffold a loop's state spine

Writes `<dir>/<name>/` with five files from the bundled templates:
`loop.config.yaml` ([assets/loop.config.template.yaml](../assets/loop.config.template.yaml)),
`STATE.md` ([assets/STATE.template.md](../assets/STATE.template.md)), `run-log.md`, `run.md`
(the headless run prompt, [assets/run.template.md](../assets/run.template.md)), and an
executable **`loop-run.sh`** ([assets/run.sh.template](../assets/run.sh.template)) — the
runner-agnostic tick wrapper any scheduler invokes (cron / Windows Task Scheduler /
systemd / by hand), **no GitHub Actions required**. Pass a known `--pattern`
(pr-watch, ci-watch, dep-bump, …) and the config is **seeded** with that
pattern's scope/goal/escalation — and, at L2+, its gate — so you get a near-ready config to
review, not blank placeholders (it audits clean immediately). Doctrine holds: it still
scaffolds at L1 by default with a graduation block.

`--host` records where ticks will execute (`local` default, or `session-cron` /
`desktop-task` / `cloud-routine` / `external`) so `loop-doctor` checks that host's real
constraints instead of assuming a local `claude -p`.

```bash
# Create .loops/pr-watch/ with config + STATE.md + run-log.md + run.md from templates:
bash scripts/loop-scaffold.sh --name pr-watch --pattern pr-watch --tier L1

# A connector-driven loop bound for a cloud routine (>=1h floor, no permission mode):
bash scripts/loop-scaffold.sh --name digest --pattern digest --host cloud-routine --cadence 1h

# Custom dir + cadence, preview without writing:
bash scripts/loop-scaffold.sh --name dep-bump --pattern dep-bump \
  --tier L2 --cadence 1d --dir .loops --dry-run
```

Refuses to overwrite a populated `<dir>/<name>/` (exit 5) unless `--force`. Atomic
writes. `--dry-run` prints what it would create and writes nothing. stdout = the created
config path.

### `scripts/loop-check.sh` — readiness scorer (run before you schedule)

The question this answers: *is this loop safe to turn on at its declared tier?* It scores
a `loop.config.yaml` against the readiness rubric — gate present, scope bounded,
escalation defined, guard + worktree at L2+, budget + kill switch set, permission mode
consistent with tier — and refuses a green light if any **critical** gap exists.

```bash
bash scripts/loop-check.sh .loops/pr-watch/loop.config.yaml   # exit 0 ready, 10 not ready
bash scripts/loop-check.sh --json .loops/dep-bump/loop.config.yaml | jq '.data[] | select(.severity=="error")'
bash scripts/loop-check.sh --min 80 .loops/ci-watch/loop.config.yaml   # raise the score bar
```

Exit **0** = ready (no errors, score ≥ `--min`), **10** = not ready (findings on stdout),
`2` usage, `3` config not found, `4` config unparseable. `--strict` counts warnings
toward the not-ready signal.

### `scripts/loop-doctor.sh` — live preflight (will it actually run?)

`loop-check` proves the config is *well-formed*; `loop-doctor` proves the loop will
*execute* — catching the "blocked at 3am" failures audit can't see. `--offline` (CI-safe):
the budget fits a tick's estimated tokens, the permission mode is achievable (not
interactive), an L3 bypass declares an isolation boundary. `--live` adds runtime preflight:
the `verify`/`guard` gate's leading binary resolves on PATH, `claude`/`git` are present,
the kill-switch sentinel's parent dir exists.

**It is host-aware.** `host:` changes what "will it run" even means, so the doctor checks
against the declared surface: a `cloud-routine` faster than its 1-hour floor is rejected at
creation; a routine with no named repos/environment/connector boundary has no gate at all
(it has no permission mode either, so demanding one there would be a false finding); a
`session-cron` host at L2+ can't run unattended and is called a predicted failure; and
`--live` is **skipped, not passed**, for a cloud routine — this machine's PATH says nothing
about a fresh cloud clone, and a green check there would be false confidence.

```bash
bash scripts/loop-doctor.sh --offline .loops/pr-watch/loop.config.yaml   # CI gate
bash scripts/loop-doctor.sh --live .loops/ci-watch/loop.config.yaml          # before scheduling
bash scripts/loop-doctor.sh --live --json .loops/dep-bump/loop.config.yaml | jq '.data[] | select(.state=="bad")'
bash scripts/loop-doctor.sh --offline .loops/digest/loop.config.yaml   # host: cloud-routine -> floor + boundary
```

Exit **0** = will run, **10** = a check predicts a runtime failure (gate binary missing,
bypass on host without isolation, budget too small for a tick), `2` usage, `3` not found,
`4` unparseable, `5` missing core dep. Run it **after** `loop-check` and before scheduling.

### `scripts/loop-estimate.py` — token/$ estimate by pattern × cadence × model (caching-aware)

Estimate spend **before** committing to a cadence — the cost of an outer loop is
runs/day × tokens/run × price, and sub-agents multiply it. It also models **prompt
caching**: a loop re-sends the same `run.md`+system prefix every tick (the Ralph
property), so the prefix should be cache-written once then read (~0.1×) — *but only if the
tick interval fits the cache TTL*. **The TTL is a choice, not a constant:** 5 minutes by
default (1.25× write) or 1 hour with `"ttl": "1h"` (2× write), so the daemon window is
~4.5 min *or* ~55 min — not a fixed 270 s. The estimator picks the cheapest TTL that stays
warm at your cadence and names it; past 1 h nothing caches at all. Mechanics and
break-even: [`claude-api-ops` caching-and-cost](../../claude-api-ops/references/caching-and-cost.md).
The estimate itself is **host-agnostic** — tokens are tokens wherever the tick fires; the
host-dependent limit is the *minimum cadence*, which `loop-doctor` enforces. Pricing reads from
`assets/model-pricing.json` (date-stamped; [`claude-api-ops`](../../claude-api-ops/SKILL.md)
is the source of truth — run its `check-model-table.py` if you suspect drift).

```bash
python scripts/loop-estimate.py --pattern pr-watch --cadence 10m --model claude-haiku-4-5
python scripts/loop-estimate.py --pattern ci-watch --cadence 15m --model claude-sonnet-5 --days 30 --json
python scripts/loop-estimate.py --list-models      # the pricing table + its as-of date
```

Exit `0` ok, `2` usage, `3` pricing file missing, `4` bad cadence/model. Output names
every assumption (runs/day, tokens/run, sub-agent multiplier) — it's an estimate, and it
says so.

### `scripts/check-pricing-sync.py` — offline drift guard (CI)

`model-pricing.json` is a *copy* of claude-api-ops's authoritative model table, and a copy
drifts silently. This offline verifier asserts every model in
[assets/model-pricing.json](../assets/model-pricing.json) matches claude-api-ops's "Current
Models" table (prices included). Both files are in-repo, so it's network-free and gates PR
CI via `tests/check-resources.sh`; live model-id drift is owned by claude-api-ops's
`check-model-table.py`.

```bash
python scripts/check-pricing-sync.py --offline   # exit 0 in sync, 10 drift, 3 a file missing
```

### `scripts/check-native-facts.py` — native-scheduling staleness guard

[references/native-scheduling.md](native-scheduling.md) encodes a **fast-moving
external surface**, and `loop-doctor` refuses configs on those numbers — so a silently
stale limit becomes a wrong refusal. `--offline` (PR CI) proves internal consistency: the
host vocabulary is *one* set across the config template, `loop-scaffold --host`,
`loop-doctor`'s case arm and the reference; the reference still carries its `Verified
<date>` stamp; and every limit the doctor enforces is still stated in the prose that
justifies it. `--live` (scheduled, never a PR gate) fetches the three published docs pages
and checks our numbers still appear in them.

```bash
python scripts/check-native-facts.py --offline   # exit 0 in sync, 10 drift, 3 file missing
python scripts/check-native-facts.py --live      # exit 7 = docs unreachable (advisory)
```

## Worked example

A complete, **audit + doctor-clean** L1 loop ships at
[assets/examples/pr-watch/](../assets/examples/pr-watch): a filled
`loop.config.yaml`, a *populated* `STATE.md`, the `run.md` run prompt, a sample
`run-log.md`, the runner-agnostic **`loop-run.sh`** (the tick wrapper, with the
kill-switch gate and `dontAsk` + allowlist baked in — point cron / Task Scheduler at it),
and an *optional* `github-actions.yml` for repos already on GitHub. Copy the dir, adjust
scope/cadence, run `loop-check` + `loop-doctor --live`, then wire `loop-run.sh` to your
scheduler. The other patterns don't ship as
static dirs that rot — `loop-scaffold --pattern <name>` *generates* the same, seeded and
gate-clean, for any pattern at any tier. CI runs `loop-check` + `loop-doctor` on this
example every build, so it can't drift out of validity.
