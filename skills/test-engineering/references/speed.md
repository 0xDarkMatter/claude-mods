# Speed mode: the same catches, in fewer seconds, on someone else's machine

**Output:** a before/after profile (`suite-profile.py compare --markdown`), the changes made
(where the suite runs, workers, selection tiers, fixture and harness fixes), and the
budget re-baselined so the gain cannot quietly erode. Speed mode never deletes a test;
that is prune mode, with its own evidence.

## Contents

- [Order of work](#order-of-work)
- [Where tests run: offload first](#where-tests-run-offload-first)
- [Local runs: always parallel, never the whole machine](#local-runs-always-parallel-never-the-whole-machine)
- [Run only what the change needs: tiers](#run-only-what-the-change-needs-tiers)
- [Where the seconds go](#where-the-seconds-go)
- [The harness is the cost: faster runners and rewrites](#the-harness-is-the-cost-faster-runners-and-rewrites)
- [Verify the gain](#verify-the-gain)

## Order of work

Measure before touching anything (audit mode's cost half gives you the profile), then work
down this list. Earlier items are cheaper and safer, and each later item multiplies the
earlier ones:

1. **Where it runs**: offload. It frees the developer's machine, whatever the suite costs.
2. **How much runs**: tiers. The cheapest test is the one a change does not need.
3. **How wide**: parallel workers and CI shards.
4. **How slow each test is**: fixtures, sleeps, network, imports.
5. **What runs them**: a faster runner, or a rewritten harness.

## Where tests run: offload first

**The default is offload.** Few suites need the developer's machine: tests rarely depend
on a GUI session, a local secret or attached hardware, and when they do, that is a smell
worth naming. Agentic work makes this matter more. Several sessions running full suites
at once is how a workstation ends up pinned at 100% CPU while a human waits.

```bash
python "<skill-dir>/scripts/run-plan.py" targets --repo . --probe   # ranked, with cost notes
```

| Target (in ranked order) | Cost | Use when |
|---|---|---|
| Another machine of yours over SSH (a home server, a spare Mac, a tailnet peer) | no metered cost | default for full and slow runs |
| A remote Docker context | the host's | the suite already runs in a container |
| CI (GitHub Actions) | free on public repos' standard runners; billed per job-minute on private (`ci-audit.py cost` gives the numbers) | the PR tier runs there anyway; `gh workflow run` for an on-demand full run |
| A metered sandbox (Codespaces, Modal, E2B, Daytona, Fly) | per second or per core-hour | heavy, bursty suites with no free machine |
| A Claude Code cloud session | the account's plan | the test run belongs to a separate task anyway |

**Advise, then prefer offload.** State the target's cost in one line when it is metered,
then use it unless the user says otherwise. Run locally only when no target exists
(`targets` exits 10), the test needs local-only hardware or state, or a sub-second
inner-loop tier is all you need.

**Shipping code without pushing.** Offload must not need a push: child sessions may not
push, and pushing a scratch branch to save CPU is the wrong trade. Send the tree instead:

```bash
# committed state
git archive HEAD | ssh <host> 'D=$(mktemp -d) && tar -x -C "$D" && cd "$D" && <install> && <test cmd> --junitxml=r.xml && cat r.xml' > r.xml
# plus uncommitted work: add the diff on top
git diff HEAD | ssh <host> 'cd <that dir> && git apply'
```

- **No credentials travel.** Send code, never `.env` files, tokens or SSH agent forwarding.
  If the suite needs a secret to run, that is an integration tier, and it runs in CI where
  secrets are scoped.
- **Install from the lockfile on the target** (`uv sync --frozen`, `npm ci`, `composer install`).
  A warm, reused directory per repo on the target saves the install on later runs.
- **Bring the JUnit XML back.** It is the evidence the profile, budget and report read.

## Local runs: always parallel, never the whole machine

When a run stays local, it is always parallel, sized to what is free right now:

```bash
python "<skill-dir>/scripts/run-plan.py" local --per-worker-mb 800
```

It holds back a quarter of the cores (at least one) and 2 GiB of memory, subtracts current
CPU load, and caps workers by memory per worker. It also reads cgroup limits inside
containers. It exits 10 when the machine is already busy (over 80% CPU, or no worker fits),
which means offload. Measure one worker's peak RSS for `--per-worker-mb`: the 1 GB default
is a guess. On Windows, watch commit headroom as well as free RAM. Node and Vite workers
exhaust the commit limit long before physical memory, and the tests then fail as random
segfaults.

| Runner | Parallel flag | Before parallelising |
|---|---|---|
| pytest | `-n <N>` (pytest-xdist), `--dist loadfile` keeps a module's fixtures in one worker | `pytest-randomly` first: order dependence surfaces as flakes under xdist |
| vitest / jest | `--maxWorkers=<N>`; vitest `--pool=threads` is cheaper than forks where isolation allows | module-level state shared through mocks |
| go | `go test -p <N>` across packages, `t.Parallel()` within | tests that `os.Chdir` or set env cannot be parallel |
| cargo | `cargo nextest run -j <N>` (process per test, so no shared-state surprises) | none: nextest is the default choice |
| phpunit / pest | paratest `--processes=<N>`, `pest --parallel` | one database per process (`TEST_TOKEN`), or transactions |
| playwright | `--workers=<N>`; `fullyParallel: true` | tests sharing one logged-in account |

## Run only what the change needs: tiers

**Conditional is the default.** A test runs because the change touched what it guards,
not because it exists. Every tier but T2 is change-aware; T2 is the safety net, not the
normal path.

| Tier | Runs | Budget | Where |
|---|---|---|---|
| **T0 inner loop** | tests for the file being edited | seconds | local, or the agent's own sandbox |
| **T1 pre-push / PR** | tests the diff affects, plus a small always-run smoke set | a few minutes | offload target or CI |
| **T2 merge / nightly** | the full suite, and slow e2e, visual and mutation tiers | whatever it needs | CI or a scheduled offload |

```bash
python "<skill-dir>/scripts/run-plan.py" stack --repo .   # each runner's changed/shard/junit command
```

| Stack | Change-aware selection (use the tool; never hand-roll a selector) |
|---|---|
| pytest | `pytest-testmon` (per-test coverage; deselects tests whose code did not change) |
| vitest | `vitest run --changed <ref>`, `vitest related <files>` |
| jest | `--changedSince=<ref>`, `--findRelatedTests <files>` |
| playwright | `--only-changed=<ref>` |
| Nx / Turborepo | `nx affected -t test`, `turbo run test --affected` |
| go | the build cache already skips unchanged packages: never `-count=1` in CI without a reason |
| cargo | `-p <changed crates>`; nextest's `--partition` for shards |
| PHP | no native selection: `affected.py` per area, `--order-by=defects` locally; Infection `--git-diff-lines` for mutation |
| shell suites, per-package monorepos, anything else | `affected.py` with a committed `.test-map.json` |

**No native selector? Map paths to tests, and fail safe.** `affected.py` reads a committed
map (rules from path globs to test commands, with `{1}` substitution for per-package layouts,
plus `always_full` and `ignore` lists) and the diff:

```bash
python "<skill-dir>/scripts/affected.py" --base origin/main            # the commands to run
python "<skill-dir>/scripts/affected.py" --base origin/main --json     # mode, commands, the file behind each
```

A file the map does not cover, an always-full path, or a deleted package's test script
all make it answer with the full suite. A missed mapping costs time, never a missed
failure. Keep the map beside the code it describes, and review it like code.

**The safety net, because selection misses things.** Static selectors cannot see config
files, fixtures, data files, migrations, environment variables or dynamic imports.
Coverage-based selectors (testmon) see only what the last run executed. So:

- **Always run the full suite on merge or nightly (T2).** A selection miss then costs hours,
  not a release.
- **Some changes always trigger the full suite**: lockfiles, test config, CI config,
  fixtures, migrations, and the test harness itself. Put these in the PR job's path filter.
- **A T2 failure the T1 run missed is a selector bug**: record which file escaped and add it
  to the always-full list.

## Where the seconds go

Read the profile's slowest tests and files first: the cost is rarely spread evenly.

| Cost | Signal in the profile | Fix |
|---|---|---|
| Fixture and setup | many fast tests in a file whose total is high; time in the first test of a module | widen the fixture scope (module or session) for read-only fixtures; build expensive data once |
| Database | each test a few hundred ms | a transaction per test, rolled back; or a template database cloned per worker. Never re-run migrations per test |
| Sleeps and real timers | times cluster at round numbers (1.0 s, 5.0 s) | fake clocks (`vi.useFakeTimers`, `freezegun`/`time-machine`, `Carbon::setTestNow`); poll with a short timeout instead of sleeping |
| Network | a long tail, flaky | fake at the process boundary (respx, msw, `Http::fake`); real network only in a tagged integration tier |
| Import and collection time | the whole run is slow but no test is | `python -X importtime`, `vitest --reporter=verbose` timings; lazy-import heavy modules; narrow `testpaths` |
| Browser startup | e2e files dominate | reuse an authenticated storage state; one browser per worker |
| Retries | `flaky` > 0 in the profile | fix the nondeterminism (triage.md). A retry doubles the cost and hides the bug |

## The harness is the cost: faster runners and rewrites

Sometimes the code under test is fast and the harness around it is slow: a runner, a
transformer, or a test suite written as shell scripts that spawn a process per
assertion. Then a faster runner or a rewrite in a compiled language is the biggest lever
left. Judge it on measurements, not fashion:

| Symptom | Faster option |
|---|---|
| jest spends its time transforming TypeScript | vitest (esbuild), or `@swc/jest` in place of `ts-jest` |
| Bun is already the runtime | `bun test` |
| Rust suite under `cargo test` | `cargo nextest` (process per test, parallel by default, JUnit output) |
| Python env setup dominates CI | uv (`uv sync --frozen`), with its cache |
| Lint or format runs inside the test job | ruff, Biome or oxlint, in a separate fast job |
| A bash or PowerShell suite spawns processes per check (each spawn costs tens of ms, more on Windows) | batch checks into one process per file; or rewrite the harness in Go or Rust when it is run often and the measured spawn cost dominates |

A harness rewrite is a project of its own, not a speed-mode step. Propose it with the
numbers: share of time spent in process spawns, runs per day, and the minutes per run it
would save. Keep the old suite running beside the new one until both agree on a full
run, including the failures it is supposed to catch (seed a mutant and watch both go red).

## Verify the gain

```bash
python "<skill-dir>/scripts/suite-profile.py" profile before/ --json > before.json
# ... changes ...
python "<skill-dir>/scripts/suite-profile.py" profile after/ --json > after.json
python "<skill-dir>/scripts/suite-profile.py" compare before.json after.json --markdown
python "<skill-dir>/scripts/budget-gate.py" baseline after.json > .test-budget.json   # lock it in
```

The same tests must still run (`removed` is empty in the compare). Parallelism that
drops tests, or selection that silently runs nothing, looks like a speed-up. Then run the
suite under the new setup three times (`suite-profile.py flakes`), because parallelism
surfaces order dependence.
