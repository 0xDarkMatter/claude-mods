# Extension Architecture — designing what to build

The other references cover the *mechanics* of each surface (hook contracts, skill
frontmatter, headless flags, debugging). This one covers the layer above: **which
surface to reach for, where to put it, and how to author it well.** Reach here when
you're designing a new agent / skill / command / hook / MCP server rather than fixing
an existing one.

## Pick the surface

Each extension surface has a job it does best. Match the need, don't default.

| Need | Surface | Why |
|------|---------|-----|
| Repeatable workflow the user kicks off | **Skill** (`user-invocable`, slash-style) | Consistent steps, on-demand body |
| Reference material / patterns loaded by keyword | **Skill** | Description always in context, body forks in on match |
| Deep multi-step reasoning in isolated context | **Subagent** | Own context window, system prompt, tool/model/permission set |
| Must-never-happen guarantee | **Hook** (or a permission deny rule) | Deterministic; runs regardless of model judgment |
| Always-on, file/path-scoped guidance | **Rule** (path-scoped) | Injected per matching file |
| Context every session needs | **CLAUDE.md** | Loaded automatically at session start |
| External capability (DB, API, service) | **MCP server** | Tools/resources the model calls |

**Decision tree:**

1. Does it *have to* happen (security, safety, an invariant)? → **Hook** or permission rule — not a skill. Skills are guidance, not guarantees.
2. Clear repeatable steps a user invokes? → **Skill** (user-invocable).
3. Reference patterns surfaced by keyword? → **Skill** (model-invocable).
4. Needs its own context window / deep reasoning / a different model? → **Subagent**.
5. Applies to specific file types or paths? → **Rule**.
6. Should the model always know it? → **CLAUDE.md**.
7. New external capability? → **MCP server** (see mcp-ops).

**Skill vs subagent (the common fork):** a skill injects prompt content into the
*current* context; a subagent runs in a *fresh, isolated* context and reports back.
Reach for a subagent when the work would pollute or blow the main context (large
multi-file analysis, long research), needs a cheaper/stronger model, or wants a
narrowed tool set. Reach for a skill when the guidance belongs inline. They compose:
a subagent can `skills:` preload full skill bodies, so "agent for the decision, skill
for the patterns" is a valid pairing rather than a duplication.

## Where to put it (scope)

| Scope | Location | When |
|-------|----------|------|
| Personal, all projects | `~/.claude/` | Your own preferences, global tooling |
| Personal, this project | `.claude/` (gitignored) | Experiments, local overrides |
| Team, this project | `.claude/` (committed) | Shared workflow, project standard |
| Enterprise | managed policy dir | Org-wide policy |

Precedence when the same thing is defined twice: managed always wins, then
local > project > user; flags/env override files. (Full resolution table in
[debugging-reference.md](debugging-reference.md).) Design corollary: put a thing at
the *widest* scope where it's still correct, and never rely on a narrow-scope file to
override a managed one — it can't.

## Author it well

### Descriptions are the trigger surface

A model-invocable skill or subagent only fires if its description matches. Write
**what it does + when to use + concrete trigger scenarios**, key phrases first (the
listing is budget-capped — see skills-reference.md).

```yaml
# Good — explicit scenarios, trigger phrases up front
description: "ECS Fargate deployment guidance. Use for: task definitions, services,
  ALB integration, awsvpc networking, FARGATE_SPOT, Service Auto Scaling."

# Poor — no trigger signal
description: "Helps with AWS"
```

Patterns that pull their weight: `Use for: X, Y, Z` (explicit scenarios),
`Use proactively when…` (encourages auto-delegation), `Triggers on: kw1, kw2`
(discovery). Start **narrow** and widen as real usage reveals missed cases — a broad
description that overlaps three other skills helps no one.

### Structure

**Subagent prompt** — focus areas (3–5), actionable approach principles
("always X before Y", "prefer A over B when C"), a *measurable* quality checklist,
named anti-patterns. Agents *generate* code; don't hard-code solutions into the prompt.

**Skill body** — quick-reference table, minimal usage, "when to use", links to
`references/` for depth. Keep `SKILL.md` lean (well under 500 lines); push detail into
supporting files that fork in on demand.

### Authoring quality bar

Before shipping any extension:

- [ ] `name` is kebab-case and matches the file/dir; frontmatter opens with `---`.
- [ ] Description names concrete trigger scenarios, not a vague capability.
- [ ] Scope is the widest one that's still correct.
- [ ] Body/prompt is lean; depth lives in `references/`, not the always-loaded surface.
- [ ] Subagent has principles + measurable checklist + anti-patterns, no embedded code.
- [ ] A guarantee is enforced by a hook/permission, not merely *described* in a skill.
- [ ] Validated (`claude plugin validate --strict` for plugins; project test runner).

## Authoring pitfalls

| Pitfall | Fix |
|---------|-----|
| Skill scope too broad / overlaps others | One technology or workflow per skill; start narrow |
| Description has no trigger keywords | Add `Use for:` / `Triggers on:` with real phrases |
| Detail crammed into the always-loaded body | Move to `references/`, link from the body |
| Code baked into a subagent prompt | Describe the pattern; let the agent generate code |
| "Be helpful" / vague principles | Concrete, testable ("always validate input") |
| Using a skill to *enforce* an invariant | Invariants belong in hooks/permissions — skills are guidance |
| Hook script with unquoted vars / hardcoded paths | Quote `"$VAR"`; root paths with `${CLAUDE_PROJECT_DIR}` (see hooks-reference.md) |

## Official references

- https://code.claude.com/docs/en/skills — Agent Skills
- https://code.claude.com/docs/en/sub-agents — subagents
- https://code.claude.com/docs/en/memory — memory + rules
- https://code.claude.com/docs/en/plugins-reference — plugin schemas
- https://www.anthropic.com/engineering/claude-code-best-practices
- https://agentskills.io/specification — Agent Skills open standard
