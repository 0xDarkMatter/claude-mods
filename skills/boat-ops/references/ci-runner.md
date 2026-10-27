# boat as a one-time GitHub Actions runner, with fallback

## Contents

- The shape: three jobs
- boat-up: mint a runner, start a box
- The box's setup script
- The gate job
- boat-down: always delete
- Fallback to GitHub's runner
- Hardening before boat becomes the default
- What it measured

Distilled from a trial on two private repos, 2026-10-26 and 10-27 [field]: every boat
run passed after one parity fix, and the design below was approved for adoption. Labels:
measured, inferred, and "not yet tested" where the trial had not proven a step.

## The shape: three jobs

| Job | Runs on | Does |
|---|---|---|
| `boat-up` | `ubuntu-latest`, 10 min | mints a just-in-time (JIT) runner config, creates the box, waits for box and runner |
| the gate (keep its existing name) | the box's unique label | the repo's normal Linux gate |
| `boat-down` | `ubuntu-latest`, `if: always()` | reads usage, deletes the box, confirms, removes the runner registration, writes the step summary |

Secrets (a boat API key and a GitHub token that can manage self-hosted runners) stay in
`boat-up` and `boat-down` on GitHub's machine. The box receives only the one-time JIT
config. Skip `boat-up` for fork and Dependabot pull requests: they get no secrets.

The workflow calls boat's REST API with curl, not the boat CLI, because the CLI download
has no pinned version or published checksum [field]. Pass the key to curl through a
header file (`-H @<(printf 'Authorization: Bearer %s\n' "$BOAT_API_KEY")`), never argv.

## boat-up: mint a runner, start a box

1. `gh api -X POST orgs/<org>/actions/runners/generate-jitconfig` with a runner name, a
   runner group id limited to the repos that use it, `work_folder=_work`, and ONE label
   unique to this run and attempt: `boat-<run_id>-<attempt>`. `::add-mask::` the
   returned `encoded_jit_config` before anything prints, and keep the runner id.
2. `POST https://boat.dev/api/v1/sandboxes` with a JSON body built by `jq`:
   `{name, type: "default", ttlSeconds: 3600, noEnv: true, snapshots: false,
   monitoring: false, files: [{path: "/home/user/jit", content: <jit>}],
   setupScript: <runner-setup.sh>}` and `Idempotency-Key: <box name>`. On 409
   `idempotency_in_progress`, retry the same request; on any other non-2xx, stop. The id
   is `.sandbox.id`.
3. Poll `GET /sandboxes/{id}` until `.sandbox.state` is `ready`, `idle` or `running`; fail
   on `error`, `cancelled`, `archiving` or `archived`.
4. Poll `gh api orgs/<org>/actions/runners/<runner_id>` until `status` is `online`; every
   few polls check the box's `setupStatus` and fail fast on `failed`.
5. If the runner never came online, print the setup log through
   `POST /sandboxes/{id}/commands` (`tail -n 80` of the log file) before failing.

Before wiring a key in, check its scope with one `GET /api/v1/orgs`: a key made while the
dashboard said boxes bill the org was still scoped to a personal account, and naming the
org in a create gave 403 `not_org_member` [field].

## The box's setup script

The `setupScript` runs after ready, in the background, and must exit non-zero on any
failure so `boat-up` sees `setupStatus` fail [field]:
- download a pinned `actions/runner` release at least 7 days old and check it against the
  SHA-256 in its release notes;
- if libicu is missing, set `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1`;
- read the JIT config from the file into `ACTIONS_RUNNER_INPUT_JITCONFIG`, delete the
  file, and start `run.sh` with the config in env, never argv;
- start the runner through the capability drop below, and refuse to start if a `chmod 000`
  probe directory is still readable.

**The capability drop (parity fix, measured).** The box user gets `CAP_DAC_READ_SEARCH`
in its ambient set from boat's agent, so a `chmod 000` directory stays readable; every
test that relies on an unreadable path failed on the first 10 boat runs [field].
`setpriv --inh-caps=-all --ambient-caps=-all` alone leaves the bounding set full, and
dropping the bounding set as the box user fails (it needs `CAP_SETPCAP`). What worked:

```bash
sudo -n --preserve-env=ACTIONS_RUNNER_INPUT_JITCONFIG,HOME,PATH \
  setpriv --reuid="$(id -u)" --regid="$(id -g)" --init-groups \
  --inh-caps=-all --ambient-caps=-all --bounding-set=-dac_read_search,-dac_override \
  ./run.sh
```

The process runs as the box user with `CapEff=0`, and `sudo` inside cannot regain the
capabilities. Prove it before every gate with a `chmod 000` probe. Don't apply it to a
Docker build: that needs the root daemon and sudo [field].

## The gate job

- `runs-on` the unique label. Start with the `chmod 000` probe and a resources step
  (nproc, memory, image, tool versions) into `$GITHUB_STEP_SUMMARY`.
- `actions/setup-python`'s Linux builds expect `/opt/hostedtoolcache`: use the box's own
  `python3 -m venv "$RUNNER_TEMP/venv"` instead. Install global npm tools under a user
  prefix (`npm install -g --prefix "$RUNNER_TEMP/npm-global"`). Some suites needed
  `env -u TMPDIR` [field].
- The image ships Node 24; a repo pinned to Node 22 downloaded it from nodejs.org and
  checked its SHA-256 (about 2 s) [field].

## boat-down: always delete

`if: always()`, so it also runs on a cancel. Read `GET /sandboxes/{id}/usage` first, then
delete and confirm as in [box-lifecycle](box-lifecycle.md#delete-and-confirm), then delete
the runner registration if it still exists (a 404 means the one-time runner already
removed itself). Write timings and the list-price cost to the step summary.

## Fallback to GitHub's runner

The trial's known gap: a JIT box serves one job, so "Re-run failed jobs" queues the gate
for a runner nobody starts. The adopted design [field, inferred; needs its own test runs]:
- keep the required job's id and name, so branch protection does not change;
- choose its runner when the job starts: `[self-hosted, boat-<run_id>-<attempt>]` when
  this attempt's `boat-up` created a box, else `ubuntu-latest`, by an expression in
  `runs-on`;
- that one change covers boat being down, a failed-job re-run (it sees no box for its
  attempt) and a cancel.

Until the fallback is in, re-run all jobs, never only the failed one.

The alternative, one listener for every repo (a GitHub App receiving `workflow_job`
events and a small Worker that starts a box per queued job), removes the two GitHub jobs
and fixes re-runs naturally, but it is a service to run and watch. The trial chose the
starter jobs until a third repo wants boat [field].

## Hardening before boat becomes the default

1. Prove the fallback with test runs: boat down, a failed-job re-run, a cancel. Keep the
   PR in draft until about 20 green runs through the CI path [field].
2. A daily sweeper deletes `ci-` boxes older than 2 hours and reports them; the 3600 s TTL
   caps the worst case meanwhile.
3. One-time runners can update themselves to a release newer than your cooldown allows,
   with no switch to stop it: record the runner version in every run's summary.
4. Narrow the boat key to what CI needs, and note both credentials' expiry dates.
5. Prove pass/fail parity per repo before trusting a new runner (the capability lesson).
6. Keep boat to repos whose data may leave your region, with no deploy secrets: never
   run deploy jobs on a box. See [security-model](security-model.md).

## What it measured

| Gate | GitHub-hosted median | boat median | Speed-up |
|---|---|---|---|
| A Python/bash validator gate | 15.1 min (10 runs) | 4.9 min direct, 6.1 min through the CI path | 3.1x, 2.5x |
| A TypeScript `pnpm check` | 76 s | 31.2 s | 2.4x |

Through the CI path, box plus runner online took 19-49 s; the rest was the gate [field].
Part of the gain is likely boat's 4 vCPU against a private repo's smaller hosted runner
(inferred, not measured).
