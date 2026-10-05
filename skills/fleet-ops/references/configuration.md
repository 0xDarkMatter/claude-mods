# Configuration

The `.claude/fleet/config` keys, the parser's grammar, the shipped `forbidden_pattern`, the test gate, and where runtime state lives.

## Why `worktree_root` defaults outside `.claude/`

That's why the default `worktree_root` is `.fleet-worktrees/` at the repo top. (Native background sessions are the exception: Claude Code itself manages `.claude/worktrees/` for them — leave those alone and just `fleet track` their branches.) Runtime state (`lanes/`, `daemon.pid`, `activity.log`) is read/write from the orchestrator only and stays under `.claude/fleet/`.

## Configuration

Optional `.claude/fleet/config`, one `key=value` per line:

```
mode=auto                            # auto | worktree | branch
worktree_root=.fleet-worktrees       # keep outside .claude/ — see "Headless agent compatibility"
test_cmd=npm run check               # if set, land runs it post-merge; else trust signal log
forbidden_pattern=NEVER_LAND|debugger;   # override — the shipped default is described below
base_branch=main
poll_interval=5
icons=unicode                        # unicode | ascii (same as FLEET_ASCII=1)
session_check=on                     # on | off — refuse to land under a live owner
session_live_secs=600                # how recently active counts as "still writing"
prune_hint=on                        # on | off — show the prunable backlog in `fleet status`
```

Zero-config works for the common case.

**The shipped `forbidden_pattern` default** (the exact regex lives at
`FORBIDDEN_PATTERN` in `scripts/fleet.sh`) refuses the two scrub markers —
`TODO_` + `SCRUB` and `FIXME_` + `BEFORE_LAND`, spelled split here deliberately —
plus lone triple-X markers via the term `(^|[^X])X{3}[^a-zX]`. A run of four or
more X's is a `mktemp` template (`push-gate-paths.` plus six X's) and passes; a
bare triple-X followed by a non-letter (a space, a colon) still refuses. A
template false-refused a landing on 2026-09-01, hence the run-aware form.

Mind the self-reference: the scrub greps every **added** diff line, so writing a
contiguous marker token — or a triple-X run — into docs, comments, or a config
example refuses the very branch that adds it. Build such tokens by concatenation
(`'TODO_''SCRUB'`), as `scripts/fleet.sh` and `tests/run.sh` themselves do.

**Grammar.** The file is *parsed*, not `source`d — it cannot execute code, and it is
not bash:

| Rule | Detail |
|---|---|
| Keys | Case-insensitive — `test_cmd` and `TEST_CMD` both work. Whitespace around the key and `=` is ignored. |
| Values with spaces | Need **no quoting**. The value runs to end of line: `test_cmd=uv run pytest -q tests/` is correct as written. |
| Quotes | Optional. `test_cmd="uv run pytest -q"` works; one layer of matching `"…"` or `'…'` is stripped. |
| Comments | A whole line starting with `#`, or a trailing ` # …` on an **unquoted** value. Quote the value to keep a literal `#`: `forbidden_pattern="TODO|#nolint"`. |
| Blank lines | Ignored. |
| Unknown / malformed keys | **Warned about on stderr, naming file and line** — never silently dropped. |

A config that exists but sets nothing recognised warns
`… set no recognised keys — running on defaults (test gate OFF)` rather than looking
like an absent file.

**`test_cmd` is the test gate.** When set, `fleet land` runs it *after* the merge
commit and, on a non-zero exit, hard-resets `base_branch` to the tip it captured *before*
merging — not `HEAD^` — dropping the lane to `FAILED`; the log shows `running test_cmd: …`.
When unset, landing is **refused** (`the landing gate is UNARMED`, naming the config path)
rather than falling through to signal.sh's weaker log gate. Worked example:

```
test_cmd=uv run pytest -q --maxfail=1
base_branch=main
```

> Fixed 2026-07-28: config keys never reached the script (documented lowercase, read
> UPPERCASE; and unquoted spaced values aren't bash assignments, with the error
> swallowed by `2>/dev/null`). Every landing before that date was gated by signal.sh
> alone — `test_cmd` had never run, on any repo. If you relied on it, you had no test
> gate. `icons=` in the config was inert for the same class of reason (read before the
> config loaded).

`fleet init`/`fleet track` append `.claude/fleet/` and `.fleet-worktrees/` to `.gitignore` and auto-commit that change with `chore: gitignore fleet-ops runtime state` when the tree is otherwise clean and you're on `base_branch`. If either condition fails, it prints an `ACTION REQUIRED` message — commit `.gitignore` yourself before landing.
