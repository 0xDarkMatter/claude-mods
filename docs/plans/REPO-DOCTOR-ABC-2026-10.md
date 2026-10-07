<!-- assets/plan.tmpl.md - the frozen v1 run-plan template. `ff-plan draft`
     scaffolds docs/plans/<RUN>.md from this file, substituting only
     repo-doctor-abc, 2026-10-07, and docs/plans/NESTED-ENTRY-DOCS-2026-10.md; every other {{BRACES}} slot is
     deliberately left for the plan author to fill (draft emits structure,
     never invents scope). The tests check template parity (section set,
     lane-table columns, machine header). Spec:
     docs/plans/FFPLAN-2026-08.md section 7; ADR-026, ADR-027, ADR-028. -->

# Run plan: `repo-doctor-abc` - build repo-doctor lanes A, B and C

**Status:** draft (2026-10-07) - **Disposable**: decisions live in the cited
spec; this doc carries only the run's shared contracts and lane table.
Cite, never restate. Every lane reads its packet first, then only the
numbered sections named there. File ownership is exclusive. FINAL REPLY
follows each packet's declared `final_reply` shape.

```
GOAL: build the repo-doctor work in docs/plans/NESTED-ENTRY-DOCS-2026-10.md (Lanes A, B, C)
SPEC: docs/plans/NESTED-ENTRY-DOCS-2026-10.md
PHASES: build, docs, verify
PACKETS: 6
CRITICAL-PATH: scan -> entrydocs -> docs -> refute
EST: 4-6 hours wall-clock assuming 1-parallel (commit headroom); about 3 hours at 3-parallel
DETECTED-CONFLICTS: 0
BOUNDS: max-turns 150 per lane (entrydocs 250); one lane at a time while commit headroom stays under the doctor's reserve
REFUTED: 2026-10-07 by codex; verdict stands; 5 findings applied to sections 1.1, 1.2, 1.4 and 2
```

## 1. Shared contracts

Every lane branches from `lane/nested-entry-docs`, which carries the spec and this
doc. The orchestrator merges each finished lane back into that branch before
spawning a lane that depends on it.

### 1.1 repo-scan facts (producer: `scan`; consumers: `entrydocs`, `scorer`)

New sections, each selectable with `--only`. Every list item carries a `source`
(`path`, `path:line`, or `cmd: ...`) like every existing fact.

```
data.nesting = {
  "recommend": [ { "dir": "packages/engine/", "points": 6,
                   "signals": [ { "kind": K, "detail": "<text>", "source": "<src>" } ],
                   "existing": { "agents_md": false, "claude_md": false } } ],
  "farms": [ { "parent": "tools/", "members": 9, "shape": "<manifest kind + root names>",
               "nest_also": ["tools/t03/"], "source": "cmd: git ls-files" } ],
  "considered": 7 }
  K is one of: own-manifest own-tests own-deploy landmine-cluster own-gate stack-differs churn

data.gates = [ { "tool": "dependency-cruiser", "config": ".dependency-cruiser.cjs",
                 "scope": "packages/engine/",          # "" for repo-wide
                 "partial": null | { "kind": "baseline|freeze|skip", "path": "<file>", "entries": 3 },
                 "wired": true | false | null,         # referenced by the check entry point; null = unknown
                 "source": "<src>" } ]

data.architecture = {
  "path": "ARCHITECTURE.md" | "docs/ARCHITECTURE.md" | null,
  "warranted": true | false,
  "reasons": ["2 nesting recommendations", ...],
  "layout": ["apps/", "packages/", "packages/engine/", ...],   # sorted: top-level tracked dirs (no dot-dirs, no generated) + workspace members
  "layout_fingerprint": "<sha1 hex of '\n'.join(layout)>",
  "entry_points": [ { "name": "packages/engine/src/index.ts",
                      "kind": "manifest-main|manifest-bin|manifest-exports|index|cmd|dunder-main",
                      "source": "<src>" } ] }

data.manifests_by_dir = { "<dir>/": <the same shape as data.manifests> }
  # every workspace member and every nesting.recommend dir; part of the "manifests" section

data.generated_entry_docs = [ { "path": "AGENTS.md", "generator": "ruler|rulesync|source-header",
                                "source_of_truth": "<repo-relative path>" | null, "source": "<src>" } ]
  # part of the "docs" section. source_of_truth is ".ruler/" for ruler, ".rulesync/" for
  # rulesync, the path a "<!-- Source: <path> -->" header names, or null when the header
  # names nothing resolvable. A consumer patches source_of_truth, never "path".
```

`--only` accepts the new names `nesting`, `gates` and `architecture`. The
schema string stays `claude-mods.repo-doctor.repo-scan/v1`: these are additive.

### 1.2 Tool profiles (producer: `profiles`; consumer: `entrydocs`)

`skills/repo-doctor/assets/agents-md/tool-profiles.json`:

```
{ "schema": "claude-mods.repo-doctor.tool-profiles/v1",
  "profiles": [ {
      "id": "claude-code", "name": "Claude Code", "verified": "2026-10-07",
      "sources": ["https://code.claude.com/docs/en/memory"],
      "entry_files": ["CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md", "AGENTS.md"],
      "per_dir": "claude-md-shadows-agents-md" | "first-match" | "all",
      "first_match_order": ["AGENTS.override.md", "AGENTS.md"],    # only for first-match
      "ancestors": "launch" | "none",
      "subdirs": "on-read" | "launch-path-only" | "always" | "never",
      "precedence": "concatenate" | "nearest-wins",
      "imports": null | { "syntax": "@path", "max_depth": 4, "skip_code": true, "relative_to": "importing-file" },
      "rule_sets": [ { "glob": ".claude/rules/**/*.md",
                       "mode": "always|scoped|description|manual|frontmatter",
                       "scope_key": "paths" | "applyTo" | "globs" | "fileMatchPattern" | null,
                       "always_when_scope_missing": true } ],
        # "frontmatter": the mode comes from each file's frontmatter (e.g. Cursor .mdc
        # alwaysApply/globs/description, Kiro inclusion). explain counts a rule file as
        # always-loaded when its effective mode is always, and as glob-loaded when its
        # scope_key glob matches the folder being explained; description and manual
        # rules are listed as reachable, never counted as loaded.
      "caps": [ { "scope": "chain|file", "bytes": 32768, "chars": null, "lines": null,
                  "behaviour": "drop-deepest|per-file|advice", "source": "<url>" } ],
      "targets_when": ["GEMINI.md", ".cursor/"],                  # repo files that show it is used; [] = always
      "facts": [ { "id": "<slug>", "claim": "<one line>", "live_phrase": "<verbatim from source>", "source": "<url>" } ]
  } ] }
```

`skills/repo-doctor/scripts/check-tool-profiles.py --offline` validates the file
(schema, every fact has a source and a `verified` date, ids unique). `--live`
fetches each source and checks each `live_phrase` appears (exit 7 if unreachable,
10 on drift), following `check-memory-docs.py`.

### 1.3 `agents-md.py explain` (producer: `entrydocs`; consumer: `docs`)

`agents-md.py explain [--repo P] <folder> [--tool ID|all] [--json]`. Exit 0, 2 usage,
3 folder not found. The `--json` schema is `claude-mods.repo-doctor.agents-md-explain/v1`:

```
{ "data": { "dir": "packages/engine/", "tools": [ {
      "tool": "claude-code",
      "files": [ { "path": "AGENTS.md", "reason": "ancestor|nested-on-read|import|always-rule|glob|fallback",
                   "bytes": 9000, "chars": 8900, "always_loaded": true } ],
      "totals": { "bytes": 0, "chars": 0, "est_tokens": 0, "always_chars": 0, "on_demand_chars": 0 },
      "caps_hit": [ { "scope": "chain", "limit": "32768 bytes", "source": "<url>" } ] } ] },
  "meta": { "schema": "claude-mods.repo-doctor.agents-md-explain/v1", "excluded": "user-scope files" } }
```

Additive fields, as built (2026-10-07):
- Each tool record also carries `name`, `notes` (import cycles, skipped user-scope imports) and `reachable` (description or manual rules, listed and never counted).
- Each file carries `lines`.
- A file-scope `caps_hit` entry adds `path` and `behaviour`.
- `reason` gains `always-nested`, for a tool that loads every nested AGENTS.md (Kiro).

Departures from contract 1.2, as built (2026-10-07, after the refute):
- `targets_when: []` means the tool is assumed in use, but `tool-cap` is reported only
  for tools a repo visibly targets. The caps of the always-assumed tools (Claude Code,
  Codex) are checked by `over-ceiling` and `root-starves-nested`, which say more.
- `check-tool-profiles.py --live` exits 7 only when every source is unreachable; with
  some unreachable it reports those rows and exits 0 (documented in its docstring).
- A cap whose fact failed live verification is not encoded (Copilot's 1,000 lines), and
  a user-scope cap never is (Windsurf's 6,000-character global rules file).

### 1.4 Ruled-out record (producer: `entrydocs`; consumer: `docs`)

`docs/agents/ruled-out.md` in the audited repo. One line per decision:

```
- [<kind>] `<path-or-glob>` [`<path-or-glob>` ...] @<count>: <reason>[ until YYYY-MM-DD][ (proposed)]
```

`<kind>` is a candidate kind (`coupling`, `fragile`, `hotspot`, `outlier`,
`config-followup`, ...). `<count>` is the evidence count when ruled out: shared
commits for coupling, fix plus revert commits for fragile, commits for hotspot,
lines for outlier. The reason is required. A `(proposed)` line is reported but
not honoured.

Honoured lines remove their candidates from `uncovered_candidates`. The audit
reports the count as `data.ruled_out` (an integer) and on its header line ("N
ruled out"). The scorer does not consume candidates, so no grade changes;
"leaves the score" in the spec means exactly this exclusion from the audit's
counts.

## 2. Lane table

| id | role | class | model | owns (exclusive) | builds | gate |
|---|---|---|---|---|---|---|
| scan | Builder | build | codex | `skills/repo-doctor/scripts/repo-scan.py`, `skills/repo-doctor/tests/repo-scan.sh`, `skills/repo-doctor/tests/fixtures.sh` | spec N1, N7 gate detection, N6 `architecture` facts, N8 generated-doc facts, per-folder manifests; contract 1.1 | auto |
| profiles | Builder | build | sonnet | `skills/repo-doctor/assets/agents-md/tool-profiles.json`, `skills/repo-doctor/scripts/check-tool-profiles.py` | contract 1.2 from the facts in its packet | auto |
| scorer | Builder | build | codex | `skills/repo-doctor/scripts/repo-doctor.py`, `skills/repo-doctor/tests/run.sh`, `skills/repo-doctor/references/scoring-rubric.md` | spec N7 scorer bullets | auto |
| entrydocs | Builder | build | sonnet | `skills/repo-doctor/scripts/agents-md.py`, `skills/repo-doctor/tests/agents-md.sh`, `skills/repo-doctor/tests/fake-gh.py`, `skills/repo-doctor/assets/agents-md/nested.md`, `skills/repo-doctor/assets/agents-md/architecture.md` | Lane A; spec N2 to N6, N7 survey and `invariant-ungated`, N8; Lane C's guided/assisted split in `scaffold --json`; contracts 1.3, 1.4 | review |
| docs | Composer | build | sonnet | `skills/repo-doctor/references/agents-md-protocol.md`, `skills/repo-doctor/references/monorepo-structure.md`, `skills/repo-doctor/references/owner-interview.md`, `skills/repo-doctor/SKILL.md`, `skills/repo-doctor/scripts/check-memory-docs.py`, `rules/agentic-quality.md`, `docs/PLAN.md`, `CHANGELOG.md`, `README.md`, `docs/plans/NESTED-ENTRY-DOCS-2026-10.md` | spec N9, Lane C workflow doc, the new Claude Code facts in check-memory-docs | review |
| refute | Adversary | verify | opus | (none: reports findings only) | attacks the integrated tree against the spec | review |

Registries the orchestrator (Warden) applies during integration: the
`check-tool-profiles.py --offline` line in `tests/check-resources.sh`, and its
`--live` step in `.github/workflows/freshness.yml`.

## 3. Dependency sketch

```
scan ──────┐
profiles ──┼──> entrydocs ──> docs ──> refute
scan ──> scorer ─────────────┘
```

- `entrydocs` depends on `scan` (consumes contract 1.1) and `profiles` (contract 1.2).
- `scorer` depends on `scan` (it calls `repo-scan.py --only gates,nesting,architecture`).
- `docs` depends on `entrydocs` and `scorer`, because it documents their behaviour.
- `refute` depends on `docs`. This is the barrier that joins the integrated tree.

## 4. Degradation plan

Drop in this order if time or headroom runs short:
1. spec N8's `--explain <finding-id>`
2. the survey's share-at-bar roll-up
3. `tool-cap` (keep `root-starves-nested`)
4. `architecture-stale-marker`

Never drop:
- Lane A
- N1 to N3
- `explain` for Claude Code and Codex
- the tests

## 5. Risk register

- **Commit headroom** (likely, high): the doctor reports room for one lane. Mitigation: one lane at a time, re-check between lanes, and stop if commit free drops under 2 GB.
- **The entrydocs lane runs out of turns** (medium, high): it carries the most work. Mitigation: progressive commits per unit and a numbered checklist. On partial, spawn `entrydocs-2` from the integrated branch with the remaining items.
- **Contract drift between scan and entrydocs** (medium, medium): mitigated by contract 1.1 frozen verbatim in both packets, with entrydocs testing against the real scanner.
- **Tool-profile facts go stale** (likely over months, low now): a `--live` check in freshness.yml.
- **Public-repo leak** (low, high): `tests/agnostic.sh` runs in every gate.

## 6. Verify plan

- **Per lane:** the orchestrator runs that lane's suites plus `tests/check-resources.sh` and reviews the three-dot diff before merging.
- **After docs:** one Adversary on Opus attacks the integrated tree against the spec and its Done-when list. Opus is a different model from the Sonnet builders and a different provider from the Codex ones. No third provider is available on this machine: the grok CLI is off limits by standing user rule, GLM's endpoint is unreachable, and pi has no provider key in the environment. The full `just check` and the orchestrator's review back it up.
- **Plan refute:** Codex, a different provider from the orchestrator that wrote the plan.
- **Before handing to MAIN:** the full `just check` on the integrated branch, run once.

## 7. Chip seats

None.
