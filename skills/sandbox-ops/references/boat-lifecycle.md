# Box lifecycle: create, run, copy, delete, confirm

## Contents

- Create and wait for ready
- Name every box
- Run commands: exec, detach, ssh
- Copy files in and out
- Lifetime: TTL, extend, stop
- Delete and confirm
- Driving boat from a Windows host
- Measured timings

Source tags as in SKILL.md: [docs] boat docs 2026-10-27, [cli] `boat help`, [driver]
fleetflow's `scripts/hosts/boat.sh`, [bench] fleetflow sandbox-bench 2026-10-22, [field]
field reports 2026-10-23 to 10-27.

## Create and wait for ready

```bash
boat --no-update new --type default --ttl 3600 --no-env --no-snapshots --no-monitoring \
  --name "<readable-name>" --json > new.jsonl
```

- `new --json` prints JSONL (`created`, then `state`, then `ready`) and returns once the
  box is ready [driver]. Take the id from the `created` event only.
- boat publishes no ready timestamp; `info.updatedAt` read straight after the `ready`
  event is the ready transition [driver].
- `--fail-fast` creates only if a machine is ready now: about 1.5 s, and when none is it
  fails with `no_ready_machine` and nothing is created, billed or counted [cli].
- `--org <id|name>` or `--personal` choose the wallet; `boat org` shows the active one.
  Over the API, a box created with no `org` field bills the key's active wallet [field].
- Docker, services and system files arrive a few seconds after `ready` [docs: llms.txt,
  "Readiness and resume speed"]. Wait for `docker info` before a build.
- The image (2026-10-22, [bench]): Ubuntu 24.04.4, git 2.43, Node 24, Python 3.12
  (`python3` only, no `python`), Docker 29.7, jq, curl, and the claude and codex CLIs
  preinstalled. The CPU was an AMD Ryzen 9 9950X on bare metal (OVH or Hetzner, FR/DE/FI).
  Check versions on the box, never assume them: the kernel differed between two boxes.

## Name every box

Name every box you create `<who>-<what>-<MMDD-HHMM>`, matching
`^[a-z0-9-]+-[a-z0-9-]+-[0-9]{4}-[0-9]{4}$`. Example: `jdoe-php83-golden-1029-1301`.

- **who** is the GitHub login, lowercased, from `gh api user --jq .login`. If that fails,
  ask the user; never guess from a git email or a folder name. A box a tool creates takes
  the tool's name instead: `ci` for CI runners.
- **what** is a short purpose slug: `php83-golden`, `ddev`, a ticket key (`abc-123`).
- **MMDD-HHMM** is the UTC date and time of the create: `date -u +%m%d-%H%M`.

```bash
who="$(gh api user --jq .login | tr 'A-Z' 'a-z' | tr -d '\r')"
boat --no-update new ... --name "$who-ddev-$(date -u +%m%d-%H%M)" --json > new.jsonl
```

Why: org boxes are visible to every member of the org that pays for them [docs], and
nothing on a box says whose it is. Boxes left with boat's default name (`Box <date>`)
could not be traced to their owner from the dashboard [field]. The name carries
ownership (who to ask before a delete), cost attribution (`boat usage <id>` gives
dollars; the name says whose they are) and orphan cleanup (a sweeper can list boxes by
owner and age without opening them).

- `--name` takes up to 120 characters [cli]. A GitHub login is at most 39 characters and
  the date 9, so what has about 70 left. Shorten what, never who or the date.
- A box started with `--from` takes the snapshot's name unless you pass `--name`
  [docs: cli-reference], so pass one there too. `--count N` gives every box the same name.
- boat does not require unique names; the box id stays the handle for every command. A
  script that finds its box again by name, or uses the name as an `Idempotency-Key`,
  puts a unique part into what: `ci-<sha12>-<random>-<MMDD-HHMM>`.
- A box already running under a bad name can be renamed with `boat rename` [cli].
- To enforce the convention, a PreToolUse hook can ask before a `boat new` whose
  `--name` does not match the pattern. Parse the command rather than grepping the raw
  string (so a commit message that mentions `boat new` stays silent), and let a name
  built at run time (holding `$` or a backquote) pass, since a hook cannot read it.
  Such a hook does not see REST creates or `boat run`.

## Run commands: exec, detach, ssh

| Need | Command | Notes |
|---|---|---|
| Short command, result as JSON | `boat --no-update exec <id> --json --timeout 120 -- bash -c '<cmd>'` | Default timeout 30 s; the API waits 600 s at most [docs: limits]. JSON has `exitCode`, `stdout`, `stderr`, `startedAt`, `finishedAt`, truncation flags [driver] |
| Long job | `exec <id> --detach -- bash -c '<cmd>'` | Prints a process id; then `--status <pid>`, `--attach <pid>`, `--kill <pid>` [cli] |
| Pipe data in | `boat --no-update ssh <id> '<cmd>' < file` | `exec` does not forward stdin [driver]; `ssh -t` gives a terminal |
| Real remote exit code over ssh | `ssh <id> '( cmd ); echo __rc=$? >&2; exit 0'` | boat turns a non-zero remote exit into rc 1 plus a JSON line; a missing sentinel means the stream was lost [driver] |

- One exec round trip is about 1.0 s median; the command itself took about 20 ms [bench].
- `--timeout` above 600, or 0, switches to live streamed output that survives network
  cuts [cli]: clamp to 600 s when you parse JSON, or use `--detach`.
- Waiting-command output is capped at 8 MiB per stream [docs: limits]; fleetflow saw
  exec stdout cut somewhere between 3.5 and 13.4 MB [driver]. Chunk large downloads.
- A retried `POST /commands` ran one gate twice at once on the same box, and two composer
  runs clobbered each other [field]. Start a detached job exactly once, then poll.
- Long gates on a box: run them detached (`nohup setsid`, or `--detach`) and poll; exec
  waits cap at 600 s [field].

## Copy files in and out

| Method | Cost | Use for |
|---|---|---|
| `ssh` stdin up, `base64` down, sha256 both ends | about 5 s a call [driver] | the default for lane files of any size the lanes use |
| `exec` + base64 stdout | 1.6 s for a 490-byte git bundle, against 14.4 s by scp [bench] | small results back |
| `exec` + base64 in argv chunks | 1 MB took 108 s in 61 calls [bench] | avoid: Windows caps a command line at 32,767 chars |
| `boat scp` | 10-15 s fixed relay cost; 10 MB in 16-18 s [bench] | big files when ssh is not an option |
| `boat push <id> <dir>` | one call | a working tree: sends only files git tracks or does not ignore [cli] |
| `--file PATH=LOCAL` at create | free | small text files (256KB total) present before ready [cli] |

- Verify every transfer with sha256, read from stdin: GNU `sha256sum` prefixes its line
  with a backslash when the FILE NAME holds one (any Windows temp path), which shifts the
  hash [driver].
- Retry a transfer once: one transient ssh read on a busy box lost a sha line, and 2 of
  150 harvests under load lost the stream though the file was on the box [driver].
- Write to `<dest>.part`, then `mv`, so a cut stream never leaves a half file.
- Only committed content crosses in a git bundle. To send gitignored inputs, build a
  throwaway ref with plumbing (`GIT_INDEX_FILE=tmp`, `git read-tree HEAD`, `hash-object -w`,
  `update-index --cacheinfo`, `commit-tree`, `update-ref`), then delete the ref [field].
- Bring results home through the log when nothing else is set up: print each file between
  markers as gzip + base64 with its sha256, decode and verify locally [field].

## Lifetime: TTL, extend, stop

- `--ttl` is seconds until auto-stop, counted from start or resume. Auto-stop defaults to
  1 hour, at most 30 days, or off (`--no-auto-stop`) [docs: limits].
- It is not an idle timeout: exec and SSH do not extend it [docs: cli-reference].
- `boat extend <id> --ttl <s>` SETS the remaining lifetime; `archiveAfter` in `info` is
  the live expiry and moves on extend, `ttlSeconds` is only the setting [driver].
- Stop is not delete. A stop keeps the disk for 14 days after a stop unless the box has
  snapshots off, where a stop erases it [docs: data-retention].

## Delete and confirm

```bash
boat --no-update delete "$id" --yes --json      # --yes is required in scripts [docs: cli-reference]
bash "<skill-dir>/scripts/confirm-gone.sh" --timeout 90 "$id"
```

- Delete is asynchronous: the box leaves `boat list` at once, the CLI prints a deletion
  operation id (`bdop_...`) and follows it [docs: cli-reference]. `boat deletion status
  <op>` reads it later: `pending`, `processing`, `blocked` (not final) or `completed`.
- Confirm by `info` answering `not_found` (fleetflow polls up to about 90 s) and by
  `boat list --all` [driver]. Plain `boat list` shows only running boxes [cli].
- Over the API: `DELETE /sandboxes/{id}` with header `X-Ascii-Confirm-Delete: <id>`
  answered 202 (or 404 when already gone); retry 409, 429 and 5xx; then poll
  `GET /sandboxes/{id}` for 404 or `GET /deletion-operations/{op}` for `completed` [field].
- A saved snapshot taken from the box keeps its data after the delete; `boat snapshot rm
  <name>` removes it [docs: cli-reference].

## Driving boat from a Windows host

| Landmine | What happens | Do instead |
|---|---|---|
| `boat scp` with a Windows path | any path containing `X:` reads as a sandbox id [driver] | `cd` to the file's folder and pass a bare name |
| Git Bash path rewriting | args that look like POSIX paths are rewritten before boat.exe sees them | `MSYS_NO_PATHCONV=1` on boat calls |
| Windows `jq.exe` | prints CRLF, and cannot open a `<(...)` `/proc` path [driver] | strip `\r`; write temp files |
| `git archive` on Windows | hook scripts arrive with CRLF | `git -c core.autocrlf=false archive ...` |
| The login config path | `%AppData%\ascii\boat\config.json` is fixed; a redirected `APPDATA` does not move it, and there is no config-path variable [field] | `BOAT_API_KEY` per process, never a second `boat login` |

## Measured timings

| Measure | Value |
|---|---|
| Create to ready, boat's clock | 0.9-1.3 s [bench]; 2.0-2.5 s from the create call, timed from Australia [field] |
| Create to first working exec | about 4.7 s [bench] |
| Upload a ~1 MB code archive | about 6 s [field] |
| Delete to `not_found` | about 2 s in the bench teardown [bench] |
