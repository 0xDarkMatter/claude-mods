# Skill Resource Protocol

> The build standard for everything a skill ships **besides** its `SKILL.md` prose:
> the `scripts/`, `assets/`, and `references/` directories. One contract, so that a
> script in `mac-ops` behaves like a script in `supply-chain-defense` — predictable
> streams, predictable exit codes, predictable help.

**Scope.** This document governs skill *resources* — the resource layer of the
[Skill Creation Protocol](SKILL-CREATION-PROTOCOL.md) (Step 4). Frontmatter, naming, and
body structure live elsewhere — see [naming-conventions.md](../rules/naming-conventions.md),
[SKILL-SUBAGENT-REFERENCE.md](SKILL-SUBAGENT-REFERENCE.md), and the
[Agent Skills spec](https://agentskills.io/specification). Terminal/TTY output is
[TERMINAL-DESIGN.md](TERMINAL-DESIGN.md) (`skills/_lib/term.sh`).

**Why it exists.** Claude executes these scripts mid-task and parses their output.
Inconsistent interfaces mean wasted tokens (the agent re-derives usage), broken pipes
(status text pollutes `| jq`), and silent failures (exit 0 on bad input). Of the many
skill scripts in this repo, the strong ones already follow this —
`supply-chain-defense/scripts/preinstall-check.sh` is the canonical exemplar.

---

## 1. Directory roles

```
<skill-name>/
├── SKILL.md            # prose: routing + 80/20 patterns + pointers
├── scripts/            # runnable code the agent executes rather than re-derives
├── references/         # deep docs loaded on demand (one concept per file)
└── assets/             # templates, reference data, starter files to copy
```

| Resource | Ship one when… |
|---|---|
| `scripts/*` | The agent would re-derive the same logic every task, OR the invocation has >3 flags, OR it's a known-good decoder/validator/verifier |
| `references/*.md` | A sub-topic is too long for the SKILL.md body (keep body < 500 lines); one concept per file, kebab-case, TOC if > 300 lines |
| `assets/*` | A task needs a known-good scaffold — a config template, a starter schema, canonical lookup data |

Every reference and asset MUST be cited from `SKILL.md` with enough context that the
agent knows *when* to load it. An unreferenced resource is dead weight the router never finds.

---

## 2. The script contract (hard rules)

A script under `scripts/` is an **agent-facing tool**. It MUST satisfy all of:

1. **Shebang + first-comment-block contract** (§3) — readable via `head -25`.
2. **`chmod +x`**, and the right extension (`.sh` bash, `.py` python3 — the agent reads
   the extension to know the runtime).
3. **`--help` / `-h`** → usage + options + an **EXAMPLES** section, exit 0, to stdout.
4. **Stream separation** (§4) — stdout is data only; everything else is stderr.
5. **Semantic exit codes** (§5) — distinct codes per failure class.
6. **Bash:** `set -uo pipefail` (use `-e` only when every failure is fatal), all
   expansions quoted. **Python:** passes `python -m py_compile`, `argparse` for args.
7. **Agent safety** (§6) — validate inputs; never `shell=True` with agent-supplied data.
8. **Cited from `SKILL.md`** with a complete worked invocation, not a bare path.

Default to **stdlib + common shell tools** (`jq`, `git`, `curl`). Check optional tools
with `command -v` and exit `5` (missing-dep) with an install hint, never a stack trace.

---

## 3. First-comment-block contract

The first comment block is the script's machine-readable contract. The agent reads it
with `head -25` before running.

```bash
#!/usr/bin/env bash
# <one-line description, ends with a period.>
#
# Usage:   <script> [OPTIONS] <ARG>
# Input:   <argv + stdin contract>
# Output:  <stdout contract — name the --json schema if structured>
# Stderr:  <what goes to stderr; e.g. "headers, progress, errors">
# Exit:    0 ok, 2 usage, 5 missing-dep, 7 unavailable, 10 <domain signal>
#
# Examples:
#   <script> simple-input
#   <script> --json input | jq '.data[]'
set -uo pipefail
```

Python uses the module docstring identically. The **Examples** section is mandatory —
it's what makes the tool discoverable when the agent runs `--help`.

---

## 4. Stream separation (the most important rule)

| Stream | Carries | Never carries |
|---|---|---|
| **stdout** | The data product only — JSON under `--json`, else plain/TSV | Progress, status, warnings, ANSI (unless TTY and not `--json`) |
| **stderr** | Everything else — headers, progress, warnings, errors, logs | The data product |

stdout is the agent's input. Pollution breaks `| jq` and downstream parsing. When
`--json` is set, an error goes to stdout **as structured JSON** (§5) *and* a human line
goes to stderr.

`--json` success envelope:

```json
{ "data": [ {"...": "..."} ], "meta": { "count": 2, "schema": "claude-mods.<skill>.<name>/v1" } }
```

`--json` error envelope (also printed to stdout):

```json
{ "error": { "code": "VALIDATION", "message": "…", "details": { } } }
```

Booleans are `true`/`false`; empty lists `[]` not `null`; timestamps ISO-8601 Z.

---

## 5. Exit codes (semantic, not just 0/1)

Distinct codes per failure **class** so the agent (and CI) can branch.

| Code | Name | When |
|---|---|---|
| `0` | SUCCESS | Operation completed; for verifiers, "no drift / all checks pass" |
| `1` | ERROR | Uncategorised failure |
| `2` | USAGE | Bad/missing arguments, conflicting flags |
| `3` | NOT_FOUND | Input file/resource absent |
| `4` | VALIDATION | Input present but invalid (malformed JSON, schema mismatch) |
| `5` | PRECONDITION | Environment issue — missing dependency, wrong cwd, no permission |
| `6` | TIMEOUT | Exceeded a time budget |
| `7` | UNAVAILABLE | External resource down/offline/rate-limited (distinct from a real failure) |
| `10`+ | DOMAIN SIGNAL | A non-error "finding" the caller branches on — document it in the header |

Codes 0/2 are required. **`10` is the workhorse for verifiers and scanners**: "ran fine,
found something." `preinstall-check.sh` exits `10` for "a package is inside the cooldown
window"; a hidden-unicode scan exits `10` on a hit. Reserve `7` for genuine
external-resource failure so a network blip never looks like a content problem — this is
what lets a live check stay advisory instead of flaky-blocking (§7).

---

## 6. Agent safety

Agents fabricate plausible inputs. The script is the last line of defence.

| Threat | Defence |
|---|---|
| Path traversal | `realpath`/`Path.resolve()`; reject paths outside the expected root |
| Shell injection | List-form `subprocess.run([...])`; **never** `shell=True` with agent input |
| Destructive ops | Require explicit `--force`/`--yes`; default to dry-run-equivalent; atomic writes (`tmp` + rename) |
| Resource exhaustion | Default a sane `--limit`; stream large inputs |
| Unknown flags / extra positionals | Hard `USAGE` error — never silently ignore |

Never write to a destination directly — write `<dest>.tmp`, then rename. Re-running with
the same inputs must be idempotent.

---

## 7. The staleness-verifier pattern (claude-mods-specific)

The repo's worst failure mode is **silent doc staleness** — a skill that was correct when
written and quietly drifts as the external world moves (model IDs, API params, GitHub
Action versions, hook events). This produced three real bugs in the v3.0 review alone.

**Any skill that encodes fast-moving external facts SHOULD ship a verifier script** with
two modes:

| Mode | Flag | Checks | Network | Where it runs |
|---|---|---|---|---|
| **Structural** | `--offline` (default in CI) | Internal consistency — the table parses, every documented item is well-formed, the shipped template is syntactically valid | No | **PR CI — may block** |
| **Live** | `--live` | Does the encoded fact still match reality? (fetch the Models API; resolve every `uses:` ref) | Yes | **Scheduled workflow — never blocks a PR** |

The rule that makes this safe: **a network-dependent assertion is never a blocking PR
gate.** It exits `7` (UNAVAILABLE) on transient failure — which the scheduled job treats
as "skip, retry next run", not "fail". Only a confirmed drift (reachable source, value
differs) exits `10`. A blocking check that goes red on a rate-limit teaches everyone to
ignore red CI — the precise way a gate dies.

Worked shape:

```bash
check-model-table.py --offline      # exit 0 (table internally consistent) — PR CI
check-model-table.py --live         # exit 10 if live Models API disagrees with the table
                                    # exit 7  if the API was unreachable (advisory, no failure)
```

The scheduled job runs `--live` weekly; on exit `10` it fails loudly (or opens an issue)
naming the exact drift. The skill stays trustworthy without making honest PRs flaky.

---

## 8. The resource-scaffold checklist

When authoring a skill, ask whether any of these would save the agent re-deriving
known-good logic. A skill may warrant zero, one, or several.

| Type | Purpose | Signals it's worth it |
|---|---|---|
| **Source / input scanner** | Static-check input before work; surface errors as structured output | Untrusted input, config files, formats with footguns (a `hooks.json`, a Terraform module) |
| **Preflight checker** | Validate environment/deps before a long step | Multi-tool pipelines, anything that crashes late |
| **Verifier / output checker** | Assert the produced artefact matches expected structure | Templates the skill ships, generated configs, the staleness pattern (§7) |
| **Calculator / triage** | Compute a domain constraint or rank findings the agent shouldn't redo by hand | Cost/budget math, parsing reports (flaky-test ranking), layout computation |

Gate question: *"Would a senior engineer in this domain reach for a small script to check
this before or after doing the work?"* If yes, the agent will too — write it once, to this
protocol.

---

## 9. assets/ taxonomy

| Kind | Example | Discipline |
|---|---|---|
| **Template** | `playwright.config.template.ts`, `github-actions-terraform.yml` | Heavily commented; mark adapt-points; a verifier (§7) should confirm it stays valid |
| **Reference data** | `exposure-catalog.json`, an IOC list | Canonical lookup the agent queries; version/date-stamp if it changes |
| **Starter code** | a minimal agentic-loop, a starter JSON schema | Smallest thing that runs and is correct to extend |

Use the target file's natural extension. Keep binary assets < 500 KB. Asset edits are part
of the skill — no separate version field; a skill commit covers SKILL.md + scripts + assets
atomically.

---

## 10. Compliance checklist

Required (a script that fails these doesn't ship):

- [ ] Shebang + first-comment-block contract with an **Examples** section
- [ ] `chmod +x`; correct extension
- [ ] `--help`/`-h` works, exits 0, lists EXAMPLES
- [ ] stdout is data-only; stderr gets progress/status/errors
- [ ] Exit codes follow §5; `USAGE`→2 on bad args
- [ ] Bash `set -uo pipefail` + quoted expansions; Python passes `py_compile`
- [ ] Input validation per §6; no `shell=True` on agent input
- [ ] Cited from `SKILL.md` with a worked invocation

Recommended (the bar for a world-class skill):

- [ ] `--json` flag, output matches the §4 envelope
- [ ] `command -v` checks for optional tools → exit 5 with install hint
- [ ] Stdlib-only where possible; degrade gracefully on missing optional deps
- [ ] Idempotent; `--force` to overwrite; atomic writes
- [ ] If it encodes external facts: the §7 `--offline`/`--live` verifier split
- [ ] A `tests/` peer suite (see `supply-chain-defense/tests/run.sh`), run by
      `tests/run-skill-tests.sh`

---

## Reference exemplars in this repo

- `skills/supply-chain-defense/scripts/preinstall-check.sh` — the canonical script:
  ecosystem flags, `--json`, exit-10 domain signal, `command -v` guards, registry-unavailable→7.
- `skills/supply-chain-defense/tests/run.sh` — offline self-test peer suite.
- `skills/_lib/term.sh` + [TERMINAL-DESIGN.md](TERMINAL-DESIGN.md) — for any script that
  prints a panel to a TTY.
