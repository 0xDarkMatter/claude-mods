# Skill and Subagent Reference

Quick reference for Claude Code skill and subagent APIs. **Always check official docs first** - this may be outdated.

## Skill Frontmatter - two layers

A SKILL.md frontmatter is governed by **two specs at once**, and they are not the same set:

1. **The [Agent Skills spec](https://agentskills.io/specification)** — the portable open
   standard (Anthropic, Vercel, Google, Microsoft, 40+ platforms). Its top-level allowlist
   is exactly six keys: `name`, `description`, `license`, `compatibility`, `allowed-tools`,
   `metadata`. Everything else it expects under `metadata`.
2. **Claude Code's skill loader** — a documented **superset** that reads *additional*
   top-level keys (`when_to_use`, `argument-hint`, `effort`, `model`, `context`, …) and
   acts on them. See [§ Claude Code top-level superset](#claude-code-top-level-superset)
   and the official table at https://code.claude.com/docs/en/skills.

**Precedence for claude-mods: Claude Code is our target** (this repo ships as a Claude
Code plugin). So the Claude Code superset fields are **valid and belong at the top level** —
that is where Claude Code reads them. **Do NOT move a Claude Code behavioural field under
`metadata` to satisfy the portable minimum: `metadata` is an arbitrary passthrough Claude
Code ignores for these semantics, so burying `argument-hint`/`effort`/`when_to_use` there
silently *disables* them** (no autocomplete hint, no effort override, no trigger surface).
`metadata` is only for genuinely non-Claude-Code custom fields (author, related-skills, …).

### Agent Skills spec — the six portable top-level fields

```yaml
---
name: skill-name                    # Required: kebab-case, 1-64 chars, must match directory name
description: "Triggers on: ..."     # Required: 1-1024 chars, include trigger keywords
license: MIT                        # Required for claude-mods skills
compatibility: "Python 3.10+..."    # Optional: 1-500 chars, runtime requirements
allowed-tools: "Read Write Bash"    # Optional: space-delimited tool names
metadata:                           # Optional: arbitrary key-value map
  author: claude-mods               # Required for claude-mods skills
  related-skills: "skill-a, skill-b"  # Comma-separated string (NOT array)
  depends-on: "skill-c"             # Comma-separated string (NOT array)
---
```

These six are the **only** keys the portable Agent Skills spec recognises at the top
level. **Claude Code adds more** (next section) — those are also legal top-level keys for
us. What does NOT belong at the top level is *custom, non-spec, non-Claude-Code* metadata
(our `author`, `related-skills`, etc.) — that goes under `metadata`.

### Custom (non-spec, non-Claude-Code) fields → `metadata`

These are claude-mods bookkeeping fields neither spec defines. They live under `metadata`
as comma-separated strings (never arrays, never top-level):

| Field | Location | Format |
|-------|----------|--------|
| `related-skills` | `metadata.related-skills` | Comma-separated string |
| `depends-on` | `metadata.depends-on` | Comma-separated string |
| `version` | `metadata.version` | String |
| `category` | `metadata.category` | String |
| `requires` | `metadata.requires` | String |
| `cli-help` | `metadata.cli-help` | String |
| `author` | `metadata.author` | String |

> **Not in this table?** If a key is a documented *Claude Code* field (below), it stays
> **top-level** — do not relocate it here.

### Rules for claude-mods Skills

1. **`license: MIT`** on every skill (exception: skill-creator has custom license)
2. **`metadata.author: claude-mods`** on every skill
3. **No empty arrays** - if `depends-on` or `related-skills` would be empty, omit them entirely
4. **No arrays in metadata** - use comma-separated strings instead
5. **Directory structure**: every skill must have `scripts/`, `references/`, `assets/` (use `.gitkeep` if empty)

### Validation

```bash
# Quick check: flag any top-level key that is NEITHER a portable Agent Skills field
# NOR a documented Claude Code top-level field. The allowlist below MUST include the
# Claude Code superset — otherwise it false-flags when_to_use/argument-hint/effort/…
# (that mistake is what PR #12 acted on).
for f in skills/*/SKILL.md; do
  awk '/^---$/{n++}
       n==1 && !/^(name|description|license|compatibility|allowed-tools|metadata|when_to_use|argument-hint|arguments|disable-model-invocation|user-invocable|model|effort|context|agent|hooks|paths|shell|disallowed-tools|  |---):/' "$f"
done

# Authoritative validation: gate on the official validator, never a hand-rolled allowlist.
claude plugin validate .
```

### Reference

- Spec: https://agentskills.io/specification
- CLI: https://github.com/vercel-labs/skills
- Directory: https://skills.sh

## Claude Code top-level superset

These are **documented Claude Code SKILL.md frontmatter fields** that the loader reads at
the **top level** and acts on. They are NOT in the portable Agent Skills spec, but since
this repo targets Claude Code they are legitimate top-level keys here. **Each is inert if
moved under `metadata`** — Claude Code only reads them at the top level. Authority:
https://code.claude.com/docs/en/skills (frontmatter table).

| Field | What Claude Code does with it | Moved to `metadata`? |
|-------|-------------------------------|----------------------|
| `when_to_use` | Appended to `description` in the skill listing as extra trigger context; counts toward the combined 1,536-char cap | Dropped — no longer supplements triggering |
| `argument-hint` | Shown in `/` autocomplete to indicate expected args (e.g. `[issue-number]`) | Dropped — no hint shown |
| `effort` | Overrides session effort while the skill is active (`low\|medium\|high\|xhigh\|max`) | Dropped — no override |
| `arguments` | Named args for `$name` substitution in the body | Dropped |
| `model` | Model override while the skill is active | Dropped |
| `disable-model-invocation` | `true` = manual `/skill` only (no auto-trigger) | Dropped |
| `user-invocable` | `false` = hidden from `/` menu, Claude-only | Dropped |
| `context` | `fork` runs the skill in a subagent (with `agent`) | Dropped |
| `agent` | Subagent type used with `context: fork` | Dropped |
| `hooks` | Skill-scoped hooks (same shape as settings.json) | Dropped |
| `paths` | Glob filters — skill loads only when matching files are in play | Dropped |
| `shell` | Shell for `` !`cmd` `` dynamic context injection (`bash`/`powershell`) | Dropped |
| `disallowed-tools` | Removes tools from the pool while active | Dropped |

```yaml
---
# example: a Claude Code skill using superset fields AT THE TOP LEVEL
name: review
description: "Code review with semantic diffs…"
when_to_use: "Use when the user asks to review staged changes or a PR…"
argument-hint: "[target|--all|--pr N] [--security|--perf]"
effort: high
license: MIT
metadata:                 # custom bookkeeping only
  author: claude-mods
  related-skills: "test-engineering, security-ops"
---
```

> **PR #12 lesson:** moving `when_to_use`/`argument-hint`/`effort` from top-level into
> `metadata` (to satisfy the portable spec's six-field minimum) **disables** them in
> Claude Code. For a Claude-Code-targeted repo, keep them top-level. The portable-minimum
> reading only makes sense for a plugin that must also run on non-Claude-Code Agent Skills
> platforms — and even then it's a trade (portability bought by losing the behaviour here).

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
