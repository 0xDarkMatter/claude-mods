# Skills Reference

Agent Skills spec as implemented by Claude Code, verified against https://code.claude.com/docs/en/skills (June 2026).

Key model change vs older guides: **custom commands have been merged into skills.** `.claude/commands/deploy.md` and `.claude/skills/deploy/SKILL.md` both create `/deploy`. Skills follow the [Agent Skills](https://agentskills.io) open standard; Claude Code extends it with invocation control, subagent execution, and dynamic context injection.

## Where Skills Live

| Location | Path | Scope |
|---|---|---|
| Enterprise | managed settings dir | Organization |
| Personal | `~/.claude/skills/<name>/SKILL.md` | All your projects |
| Project | `.claude/skills/<name>/SKILL.md` | This project |
| Plugin | `<plugin>/skills/<name>/SKILL.md` | Where enabled (namespaced `plugin:skill`) |

- Same-name conflicts: enterprise > personal > project. Plugin skills are namespaced so they never conflict. A skill beats a same-named `.claude/commands/` file.
- Project skills also load from `.claude/skills/` in **parent** directories up to the repo root, and on demand from **nested** `.claude/skills/` when working in subdirectories (monorepos).
- `--add-dir` / `/add-dir` directories DO load their `.claude/skills/` (exception to the file-access-only rule); the `permissions.additionalDirectories` setting does NOT.
- **Live change detection:** edits to SKILL.md under watched skill directories take effect within the session, no restart. A brand-new top-level skills directory needs a restart. For skill-folders-as-plugins, `hooks/`, `.mcp.json`, `agents/` changes need `/reload-plugins`.
- Add `.claude-plugin/plugin.json` inside a skill folder and it loads as a plugin named `<name>@skills-dir` (can then bundle agents, hooks, MCP servers).

## Frontmatter Reference (full, current)

All fields optional; `description` strongly recommended.

| Field | Meaning |
|---|---|
| `name` | Display name in listings. Defaults to directory name. Does NOT change the `/command` you type (except plugin-root SKILL.md, where it does). |
| `description` | What it does + when to use. Claude's trigger signal. If omitted, first paragraph of body is used. |
| `when_to_use` | Extra trigger context (phrases, example requests). Appended to description in the listing. Combined description+when_to_use truncated at **1,536 chars** in the listing. |
| `argument-hint` | Autocomplete hint, e.g. `[issue-number]` or `[filename] [format]`. |
| `arguments` | Named positional args for `$name` substitution. Space-separated string or YAML list; names map to positions in order. |
| `disable-model-invocation` | `true` = only the user can invoke (`/name`). Removes description from Claude's context entirely; also prevents preloading into subagents. Use for side-effect workflows (`/deploy`, `/commit`). Default `false`. |
| `user-invocable` | `false` = hidden from the `/` menu; only Claude can invoke. For background knowledge. Default `true`. Menu visibility only — does not block the Skill tool. |
| `allowed-tools` | Tools usable **without permission prompts** while the skill is active (grant, not restriction). Space/comma-separated string or YAML list. Permission-rule syntax works: `Bash(git add *)`. For project skills, requires workspace trust. |
| `disallowed-tools` | Tools **removed from the pool** while active. Restriction clears on your next message. |
| `model` | Model while active (same values as `/model`, or `inherit`). Applies for the rest of the turn; session model resumes next prompt. |
| `effort` | `low`/`medium`/`high`/`xhigh`/`max` while active; overrides session effort. |
| `context` | `fork` = run in a forked subagent context; the skill body becomes the subagent's prompt (no conversation history). |
| `agent` | Subagent type when `context: fork` (`Explore`, `Plan`, `general-purpose`, or custom). Default `general-purpose`. |
| `hooks` | Hooks scoped to the skill's lifecycle (same YAML shape as settings hooks; see hooks-reference.md). |
| `paths` | Glob patterns gating auto-activation: skill loads only when working with matching files. Comma-separated string or YAML list. |
| `shell` | `bash` (default) or `powershell` for `` !`cmd` `` injection. `powershell` requires `CLAUDE_CODE_USE_POWERSHELL_TOOL=1`. |
| `license` | License identifier (Agent Skills spec field). |
| `compatibility` | Environment requirements (Agent Skills spec field). |
| `metadata` | Arbitrary key/value strings (author, etc.). |

### Invocation matrix

| Frontmatter | You invoke | Claude invokes | Context cost |
|---|---|---|---|
| (default) | Yes | Yes | Description always in context; body loads on invoke |
| `disable-model-invocation: true` | Yes | No | Nothing in context until you invoke |
| `user-invocable: false` | No | Yes | Description always in context |

## String Substitutions

| Token | Expands to |
|---|---|
| `$ARGUMENTS` | Full argument string as typed. If absent from body, args are appended as `ARGUMENTS: <value>` |
| `$ARGUMENTS[N]` | N-th argument, 0-based, shell-style quoting (`"hello world"` = one arg) |
| `$N` (`$0`, `$1`, …) | Shorthand for `$ARGUMENTS[N]` — **note: `$0` is the FIRST argument** |
| `$name` | Named arg declared in `arguments:` frontmatter |
| `${CLAUDE_SESSION_ID}` | Current session ID |
| `${CLAUDE_EFFORT}` | Current effort level (`low`…`max`; ultracode reports `xhigh`) |
| `${CLAUDE_SKILL_DIR}` | Directory containing this SKILL.md — use for bundled script paths |

Escape a literal dollar before a digit/`ARGUMENTS`/declared name with a single backslash: `\$1.00`.

## Dynamic Context Injection

`` !`command` `` runs **before** Claude sees the skill content; output replaces the placeholder. This is preprocessing — Claude never executes it.

```yaml
---
name: pr-summary
description: Summarize changes in a pull request
context: fork
agent: Explore
allowed-tools: Bash(gh *)
---

- PR diff: !`gh pr diff`
- Changed files: !`gh pr diff --name-only`
```

Rules:
- `!` must be at line start or after whitespace (`` KEY=!`cmd` `` stays literal).
- Single pass: emitted output is not re-scanned for placeholders.
- Multi-line commands: fenced block opened with ```` ```! ````.
- `"disableSkillShellExecution": true` in settings replaces each command with `[shell command execution disabled by policy]` (bundled/managed skills unaffected).
- Include the word `ultrathink` anywhere in the body to request deeper reasoning when the skill runs.

## Skill Content Lifecycle (token economics)

- Invoked skill content enters as a single message and **stays for the whole session**; not re-read on later turns. Write standing instructions, not one-time steps.
- Auto-compaction re-attaches each invoked skill's most recent invocation: first **5,000 tokens** per skill, **25,000-token combined budget**, most-recent first — older skills can drop entirely.
- Keep SKILL.md under **500 lines**; push detail to supporting files referenced from SKILL.md (progressive disclosure).

## Description Budget (why skills stop triggering)

- All skill names always listed; descriptions fit a budget of **1% of the model context window** (raise via `skillListingBudgetFraction` setting, e.g. `0.02`, or `SLASH_COMMAND_TOOL_CHAR_BUDGET` env var for a fixed char count).
- Per-skill cap: combined `description` + `when_to_use` truncated at 1,536 chars (configurable via `skillListingMaxDescChars`). **Put key trigger phrases first.**
- On overflow, least-used skills lose their descriptions first: Claude can still invoke them but is less likely to pick one on its own. `/doctor` estimates the listing's cost, `/skill-doctor` compares cost with use, and `claude --debug` logs an over-budget warning. `"name-only"` in `skillOverrides` renders identically, so check it before blaming the budget; it does not reach plugin skills.
- `skillOverrides` in settings (or `/skills` + `Space`): `"on"` / `"name-only"` / `"user-invocable-only"` / `"off"` per skill. Plugin skills are managed via `/plugin` instead.

## Permission Control over Skills

```text
Skill                 # deny rule: disable Claude's skill invocation entirely
Skill(commit)         # exact match
Skill(review-pr *)    # prefix match with any args
```

## Skills x Subagents (two directions)

| Approach | System prompt | Task | Also loads |
|---|---|---|---|
| Skill with `context: fork` | From `agent` type | SKILL.md content | CLAUDE.md, except Explore/Plan agents |
| Subagent with `skills:` frontmatter | Agent's markdown body | Claude's delegation message | Full preloaded skill content + CLAUDE.md |

Subagent `skills:` preloading injects **full skill content** at startup (not just descriptions). Skills with `disable-model-invocation: true` cannot be preloaded.

## Skills in Headless Mode

`/skill-name args` works inside a `-p` prompt string — Claude Code expands it before running:

```bash
claude -p "/summarize-changes" --output-format json
```

## Minimal Working Example

```yaml
---
name: summarize-changes
description: Summarizes uncommitted changes and flags risks. Use when the user asks what changed or wants a commit message.
---

## Current changes

!`git diff HEAD`

## Instructions

Summarize the changes above in two or three bullets, then list risks.
```
