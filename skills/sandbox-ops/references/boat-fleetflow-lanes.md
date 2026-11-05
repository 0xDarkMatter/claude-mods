# boat as a lane host: fleetflow remote lanes, heavy jobs, web tools

## Contents

- fleetflow remote lanes
- How many lanes fit on a box
- Codex lanes on a box
- Web tools on lanes
- Heavy-job offload
- The driver's invariants

fleetflow ([its own repo](https://github.com/0xDarkMatter/fleetflow)) owns the remote-lane
runtime; this page is what an operator needs. Source tags as in SKILL.md; [ff] is
fleetflow's SKILL.md, 2026-10-27.

## fleetflow remote lanes

```bash
FLEETFLOW_REMOTE=1 ff spawn ... --worktree --host boat:new --token-record <uid>   # or --api-key-record
ff host up boat                     # one box for a wave; then give every lane --host boat:<box>
```

- A lane is seeded from a git bundle, runs gated (`dontAsk` + an allowlist + the kill
  guard), mirrors its events home, and is harvested (branch, session dir, metrics) before
  the box is deleted [ff].
- **No harvest, no teardown.** A lane whose work did not come home exits 19 and keeps its
  box; `ff host harvest --run R --id I` brings it home [ff].
- **At scale, detach.** `--detach` makes `ff spawn` exit 21 once launched; one watcher
  per box (`ff host watch`) polls and harvests. Wait for the lane's `result` record, never
  for exit 21 [ff].
- The credential crosses once, on the launch stream's stdin, into the worker's env only;
  `ANTHROPIC_API_KEY` is unset so it cannot outrank the token. Claude lanes only;
  `bypassPermissions` is refused [ff].
- `FLEETFLOW_REMOTE=0` (the default) refuses every `--host`. Which repo may go to a box is
  a data decision, not a flag: see [boat-security](boat-security.md).
- Keep lane ids to 10 characters or fewer (the Bash sandbox socket-path limit; SKILL.md,
  Naming).
- Auto mode refuses an agent step that puts a credential on a third-party VM. The fix is
  the user's: a permission rule for the exact command, called as one plain command with
  absolute paths and no `VAR=` prefix so the rule matches, or leaving auto mode [driver].

## How many lanes fit on a box

Measured on one `default` box (4 vCPU, 8 GB), driven from Australia [driver]:

| Lane | Per lane | Limit |
|---|---|---|
| Haiku finder | about 113-180 MB at box level | 54 concurrent before the box thrashed (no OOM; load 114, 55 MB free) |
| Sonnet build | PSS p50 188-197 MB, max about 300 MB; about 163 MB at box level | 35 before the first strain signal (swap +37 MB, CPU PSI up to 41) |

Size a ramp by lane wall time, not by the clock: a run that replaces each finished lane
launches about target x elapsed / lane wall lanes in all [driver].

## Codex lanes on a box

`codex exec -s workspace-write` fails every tool call with `bwrap: Unexpected capabilities
but not setuid, old file caps config?` [field, measured 2026-10-22]. The cause is boat's
agent service granting `AmbientCapabilities=CAP_DAC_READ_SEARCH`, which every exec child
inherits; a non-setuid bwrap refuses to start holding any capability. The fix, verified
2026-10-23, needs no sudo:

```bash
setpriv --inh-caps=-all --ambient-caps=-all -- codex exec --approve-for-me <grants> ...
```

- With it, the workspace-write sandbox is real: the lane's tree is writable; `$HOME`,
  other lanes' trees and `.git/config` are refused; network is closed inside [field].
- Keep the `--add-dir` grants route. A `-P :workspace` profile silently drops the
  writable-root grants and the lane cannot commit [field]. Re-verify on every codex-cli
  bump.
- Caveats for sharing a box: `/tmp` is shared and writable, and reads are not confined,
  so every lane can read every file on the box. Credentials therefore never go in a file.
- Use Codex's sandbox, never `-s danger-full-access`.

## Web tools on lanes

A lane allowed `WebSearch` and `WebFetch` still lacked both [field, measured 2026-10-25].
The repo's committed `.claude/settings.json` denied them by bare name. Claude Code ignores
an untrusted workspace's allow rules but applies its deny rules, and a bare-name deny
removes the tool from the registry.
- fleetflow now refuses such a remote lane before staging (result rc 2, `ff spawn` exits
  10), instead of letting it run blind.
- For a read-only lane with the kill guard on, `FLEETFLOW_REMOTE_WEB_LIFT=1` runs the lane
  with `--setting-sources user`, passes the repo's other deny and ask rules back as
  `--disallowedTools`, and journals the lift.
- Local lanes still lose a by-name-denied tool silently (open as of 2026-10-25). Check a
  repo's `permissions.deny` before briefing a lane that needs the web.

## Heavy-job offload

Full gates, land checks, renders, pose tracking and test fan-outs froze a 32-core desk
when they stacked [field]. Route them to a box:
1. Bundle the exact commit (only committed content crosses; build a throwaway ref for
   gitignored inputs, see [boat-lifecycle](boat-lifecycle.md#copy-files-in-and-out)).
2. Create a box sized to the job (`large` for CPU-bound work), provision the tools, run
   the command from the repo root.
3. Bring outputs back through the log (gzip + base64 + sha256 between markers) or a
   verified `get`, then delete the box whatever happened.
4. Parallel workers on a fresh box raced on a first model download; run a one-worker
   warm-up pass first [field].

Measured: three `large` boxes returned a pose-tracking job's output intact for $0.0053
[field]. Locally, keep to single small test files while boxes do the heavy work.

## The driver's invariants

fleetflow's `scripts/hosts/boat.sh` is the reference implementation: one verb per call
(`meta up exec stream spawn put get down ttl extend usage list links`), JSON on stdout,
exit 0 / 2 usage / 3 unsupported verb / 5 CLI missing / 7 provider failure. A remote
command that exits non-zero is not a driver failure: `exec` exits 0 and reports
`exit_code`. Reuse it rather than re-deriving the gotchas in SKILL.md's landmine table.
