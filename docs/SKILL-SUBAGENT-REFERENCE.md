# Skill and Subagent Reference

Quick reference for Claude Code skill and subagent APIs. **Always check official docs first** - this may be outdated.

## Skill Frontmatter - the rule

**Every top-level frontmatter key must be one of the six [Agent Skills spec](https://agentskills.io/specification)
fields or one of Claude Code's fourteen documented fields** (both tables below). Any other
key is either a typo or belongs under `metadata`, as a string value. Every skill must also
pass the rest of the spec's reference validator: `name` rules and directory match,
`description` 1-1024 chars, `compatibility` up to 500 chars, and frontmatter that
strictyaml can parse.

`bash tests/spec.sh` enforces all of this with the spec's own validator, `skills-ref`. It
runs in `just check` and CI. The gate's field list is
[`tests/spec-check.py`](../tests/spec-check.py) `CLAUDE_CODE_FIELDS`, and it fails if this
doc's Claude Code table stops listing every field in it.

### Why claude-mods deviates from the spec, and what that costs

What each authority says (verified 2026-10-05):

| Source | Fields outside the spec's six |
|---|---|
| Spec text (agentskills.io) | Defines six fields. `metadata` is where "clients can store additional properties not defined by the spec". |
| Spec reference validator, `skills-ref` | Rejected: "Unexpected fields in frontmatter". |
| claude.ai uploads, the Skills API, `package_skill.py` | Rejected with a hard error: "Unexpected key(s) in SKILL.md frontmatter". |
| Claude Code ([skills docs](https://code.claude.com/docs/en/skills)) | Its own fields are read **only at the top level**, and the contents of `metadata` are ignored. |

So no layout satisfies both. Under `metadata` the Claude Code fields pass the validator but
stop working: no autocomplete hint, no effort override, no trigger text. PR #12 made exactly
that move and silently disabled them. claude-mods ships as a Claude Code plugin, and its
users and maintainers run it in Claude Code, so **Claude Code's fields stay top-level**
(decision 2026-10-05).

The cost: a skill that uses any of them can't be uploaded to claude.ai or the Skills API
as-is. That matters for personal skills used in Cowork, cloud sessions and routines. Other
Agent Skills clients also ignore those fields, so they never see `when_to_use` trigger text.
`tests/spec.sh` prints how many skills this applies to on every run. If uploads ever
matter, strip or fold the fields at export time. **Never move them into `metadata`.**

### The six spec fields

```yaml
---
name: skill-name                    # Required: 1-64 chars, a-z 0-9 and single hyphens, must equal the directory name
description: "Triggers on: ..."     # Required: 1-1024 chars, include trigger keywords
license: MIT                        # Required for claude-mods skills
compatibility: "Python 3.10+..."    # Optional: 1-500 chars, runtime requirements
allowed-tools: "Read Write Bash"    # Optional: space-separated string (Claude Code also takes a list; the spec doesn't)
metadata:                           # Optional: map of string keys to string values
  author: claude-mods               # Required for claude-mods skills
  related-skills: "skill-a, skill-b"  # Comma-separated string (NOT a list)
  depends-on: "skill-c"             # Comma-separated string (NOT a list)
---
```

### Claude Code fields (fourteen, top-level only)

Each one does nothing if moved under `metadata`. Authority: the frontmatter table at
https://code.claude.com/docs/en/skills. When Claude Code documents a new field, add it
here **and** to `CLAUDE_CODE_FIELDS` in `tests/spec-check.py`.

| Field | What Claude Code does with it |
|-------|-------------------------------|
| `when_to_use` | Appended to `description` in the skill listing as extra trigger context; counts toward the combined 1,536-char cap |
| `argument-hint` | Shown in `/` autocomplete to indicate expected args (e.g. `[issue-number]`) |
| `arguments` | Named args for `$name` substitution in the body |
| `disable-model-invocation` | `true` = manual `/skill` only (no auto-trigger, no subagent preload, no scheduled-task run) |
| `user-invocable` | `false` = hidden from `/` menu, Claude-only |
| `disallowed-tools` | Removes tools from the pool while active |
| `model` | Model override while the skill is active (or the forked subagent's model with `context: fork`) |
| `effort` | Overrides session effort while the skill is active (`low\|medium\|high\|xhigh\|max`) |
| `context` | `fork` runs the skill in a subagent (with `agent`) |
| `agent` | Subagent type used with `context: fork` |
| `background` | With `context: fork`, `false` waits for the subagent's result in the invoking turn |
| `hooks` | Skill-scoped hooks, live for the rest of the session once invoked. Review these like any other hook: they run commands |
| `paths` | Glob filters - skill loads only when matching files are in play |
| `shell` | Shell for `` !`cmd` `` dynamic context injection (`bash`/`powershell`) |

```yaml
---
# example: a Claude Code skill using its fields AT THE TOP LEVEL
name: review
description: "Code review with semantic diffs…"
when_to_use: "Use when the user asks to review staged changes or a PR…"
argument-hint: "[target|--all|--pr N] [--security|--perf]"
effort: high
license: MIT
metadata:                 # custom bookkeeping only
  author: claude-mods
  related-skills: "testgen, security-ops"
---
```

### Custom (non-spec, non-Claude-Code) fields → `metadata`

These are claude-mods bookkeeping fields that neither spec defines. They live under
`metadata` as strings (never lists, never top-level):

| Field | Location | Format |
|-------|----------|--------|
| `related-skills` | `metadata.related-skills` | Comma-separated string |
| `depends-on` | `metadata.depends-on` | Comma-separated string |
| `version` | `metadata.version` | String |
| `category` | `metadata.category` | String |
| `requires` | `metadata.requires` | String |
| `cli-help` | `metadata.cli-help` | String |
| `author` | `metadata.author` | String |

> **Not in this table?** If a key is a documented *Claude Code* field (above), it stays
> **top-level**. Do not move it here.

### Rules for claude-mods Skills

1. **`license: MIT`** on every skill (exception: skill-creator has custom license)
2. **`metadata.author: claude-mods`** on every skill
3. **No empty arrays** - if `depends-on` or `related-skills` would be empty, omit them entirely
4. **No arrays in metadata** - use comma-separated strings instead. The spec requires string
   values, but `skills-ref` 0.1.1 stringifies a list and passes it, so `tests/spec.sh` checks this itself
5. **Block-style YAML only** - `skills-ref` parses frontmatter with strictyaml, which rejects
   flow style (`[a, b]`, `{k: v}`) even where Claude Code would accept it. Put list items on
   their own `- item` lines
6. **Directory structure**: every skill must have `scripts/`, `references/`, `assets/` (use `.gitkeep` if empty)
7. **The size rule** - the one statement of it; every other doc points here:
   - **SKILL.md body under 500 lines AND under ~5,000 tokens** (characters / 3.6,
     frontmatter excluded; about 18,000 characters). Both limits bind: a dense 300-line
     body can still pass 5,000 tokens. After auto-compaction Claude Code re-attaches only
     the first 5,000 tokens of each invoked skill (25,000 across all skills), so anything
     later silently drops. Put the procedure and hard rules first and move detail into
     `references/`. `tests/skill-size.sh` warns over the token line (`--strict` fails).
   - **References one level deep, one topic each.** Link every reference directly from
     SKILL.md; one that only another reference links to may be read partially.
   - **A reference over 100 lines opens with a `## Contents` list**, so a partial read
     still sees the whole map. Some skill suites also cap each reference at 300 lines;
     that is the skill's own choice, enforced in its `tests/run.sh`, not a repo rule.

   Sources: the spec ("Progressive disclosure": under 5,000 tokens and 500 lines; "File
   references": one level deep), Claude Code's skills docs (500 lines; the compaction
   budget) and Anthropic's skill authoring best practices (500 lines; table of contents
   past 100 lines). Links under Reference below.

### Validation

```bash
bash tests/spec.sh   # official skills-ref + the Claude Code fields above (in `just check` and CI)
```

`claude plugin validate` checks the plugin and marketplace manifests only. **It does not
read SKILL.md frontmatter.** A skill with a mismatched `name`, an unknown key and a
flow-style list passed it on 2026-10-05, so it is no substitute for `tests/spec.sh`.

### Reference

- Spec: https://agentskills.io/specification
- Reference validator: https://github.com/agentskills/agentskills/tree/main/skills-ref
- Claude Code frontmatter: https://code.claude.com/docs/en/skills
- Skill authoring best practices: https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices
- CLI: https://github.com/vercel-labs/skills
- Directory: https://skills.sh

## Subagent Options

| Field | Values | Purpose |
|-------|--------|---------|
| `permissionMode` | default, acceptEdits, bypassPermissions | Control autonomy |
| `skills` | [skill-names] | Preload skills in subagent |
| `model` | sonnet, opus, haiku | Override model |

## Decision Framework: Main Context vs Fork

| Question | If Yes | If No |
|----------|--------|-------|
| Needs current session state (tasks, conversation)? | Main context | Consider fork |
| Output verbose (>500 lines)? | Consider fork | Main context |
| Needs user interaction during execution? | Main context | Consider fork |
| One-shot research/analysis task? | Fork | Main context |

## Skills Using Subagent Isolation

| Skill | Method | Why |
|-------|--------|-----|
| `introspect` | Task agent (background) | Session log analysis is verbose |

## Session Commands Analysis

| Command | Context | Rationale |
|---------|---------|-----------|
| `/sync` | Main | Must restore session state (tasks, context) |
| `/save` | Main | Must access current tasks via TaskList |

These MUST run in main context - subagent isolation would break their core functionality.
