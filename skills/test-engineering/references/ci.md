# CI: what each change pays, and how to pay less

Pipeline economics for test jobs. Workflow syntax in general lives in ci-cd-ops; this
file covers what makes a test pipeline cheap per change. Measure first:

```bash
python "<skill-dir>/scripts/ci-audit.py" cost --limit 50 --rates rates.json   # billed minutes, $ per change
python "<skill-dir>/scripts/ci-audit.py" lint                                  # CI1-CI4 below
```

## Contents

- [How GitHub bills](#how-github-bills)
- [The cheap defaults (CI1-CI4)](#the-cheap-defaults-ci1-ci4)
- [Shape of a tiered pipeline](#shape-of-a-tiered-pipeline)
- [Shards and job splits](#shards-and-job-splits)
- [Runner sizing](#runner-sizing)
- [Reports](#reports)
- [Flakes in CI](#flakes-in-ci)
- [Secrets](#secrets)

## How GitHub bills

- **Per job, rounded up to the whole minute.** Ten 20-second jobs bill ten minutes.
  `ci-audit.py cost` reports billed minutes beside wall-clock for this reason.
- **Runner OS multiplies the rate.** Windows and macOS minutes cost several times Linux
  minutes. Run cross-OS jobs only where OS behaviour is the thing under test (path handling,
  line endings, shell quirks), and on the tier that needs them (often T2).
- **Public repos on standard runners are free; private repos pay** past the plan's
  included minutes. Rates change, so `ci-audit.py` builds none in: pass `--rates`
  with your plan's numbers.
- **A cancelled run still bills what it ran.** `cancelled_billed_min` shows what
  superseded pushes cost before cancel-in-progress stopped them.

## The cheap defaults (CI1-CI4)

What `ci-audit.py lint` checks, and the fix for each:

```yaml
on:
  pull_request:
    paths-ignore: ["**.md", "docs/**"]          # CI3: docs-only changes skip the suite
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true                       # CI1: a new push cancels the old run
jobs:
  test:
    timeout-minutes: 15                          # CI2: a hang costs 15 minutes, not 6 hours
    steps:
      - uses: astral-sh/setup-uv@<sha>           # CI4: a dependency cache
        with: { enable-cache: true }
```

- **CI3 path filters vs required checks:** a required check that is skipped by a path filter
  leaves the PR waiting forever. Either filter inside the job (a cheap first step that exits
  early) or make the required check a summary job that always runs.
- **Never cancel-in-progress on the default branch's deploy or release workflows**, where a
  half-finished run is worse than a duplicate one. Use `cancel-in-progress: ${{ github.event_name == 'pull_request' }}`.

## Shape of a tiered pipeline

Tiers are defined in [speed.md](speed.md#run-only-what-the-change-needs-tiers). In CI:

| Job | Trigger | Runs | Blocks merge |
|---|---|---|---|
| `fast` | every PR push | lint, typecheck, the exact gate checks ([gate.md](gate.md)) | yes |
| `affected` | every PR push, after `fast` | change-aware selection + always-run smoke + the budget gate | yes |
| `full` | merge to main, nightly, and PRs touching the always-full paths | the whole suite, sharded | on main: alerts, and a red `full` blocks the next release |
| `slow` | nightly | e2e journeys, visual, mutation audits | no: report and triage |

Fail-fast ordering: the cheapest job that can fail goes first and gates the rest (`needs:`),
so a lint error never pays for a test run. Inside a job, `pytest -x`, `--bail`, or
`--order-by=defects` stop at the first failure on PR tiers. Never in `full`, which needs
the whole picture.

Template: [`assets/ci-tiers.yml`](../assets/ci-tiers.yml).

## Shards and job splits

- **Shard by duration, not by file count.** `pytest-split` reads stored durations; vitest,
  jest and playwright `--shard=i/N`; nextest `--partition hash:i/N`. Feed duration data from
  the last `full` run's JUnit (suite-profile's per-file times).
- **Each shard pays setup** (checkout, install, cache restore) and is billed rounded up.
  Shard until a shard's test time is a few times its setup time, and no further. Two shards
  of 3 minutes beat eight of 40 seconds.
- **Split jobs only where they run in parallel and fail independently.** A job split that
  runs sequentially only adds setup.

## Runner sizing

A larger runner costs more per minute and finishes sooner. It pays off when the suite is
CPU-bound and parallel (workers scale with cores) and the per-minute multiple is below the
speed-up. Measure one run each way before switching. A suite bound by I/O or a single
thread gains nothing from cores. Self-hosted runners (your own machines, with `run-plan.py
targets` listing candidates) carry no per-minute charge, but they hold state between runs:
use ephemeral runners or a clean checkout, never a long-lived dirty workspace.

## Reports

Always write JUnit XML, and upload it (`if: always()`) as an artifact. It is the input
for `suite-profile.py`, the budget gate, and flake history. Coverage reports are a
diagnostic (no thresholds: `coverage-check.sh` is report-only by default).

## Flakes in CI

Retries keep CI moving and hide the flake. If retries are on (`--reruns`, Playwright
`retries`, nextest `retries`), the JUnit records each pass-on-retry, and
`suite-profile.py profile` counts it as `flaky`, never green. A quarantine (`skip` or a
`flaky` marker) needs an owner and a date ([triage.md](triage.md)).

## Secrets

Unit and PR tiers need no secrets: tests fake at the process boundary. Integration tests
that do need one run in a job with a GitHub `environment` (scoped secrets, optional
approval), never on `pull_request_target` from forks.
