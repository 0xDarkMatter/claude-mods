# Risk Tiers ↔ Claude Code's permission model

The single best idea in loop engineering is **graduated autonomy**: a loop earns the
right to act unattended, it isn't granted it. This file maps the L1→L2→L3 ladder onto
Claude Code's *actual* permission machinery — which is what makes this skill more than a
generic-agent methodology. The authority for the gate behaviour is the repo's
[auto-mode-classifier reference](../../../docs/AUTO-MODE-CLASSIFIER.md); read it for the
full two-gate model. This file is the loop-specific projection.

---

## The ladder

```
L1 Report ───────► L2 Assisted ───────► L3 Unattended
read-only          suggest + human-gate    autonomous within a denylist
(plan/dontAsk)     (dontAsk/auto)          (bypassPermissions, ISOLATED only)
```

**Never skip a rung.** A fresh loop starts at L1. It graduates only after its reports
prove its judgment over real runs. Each rung adds exactly one new power and one new
guardrail.

| | L1 Report | L2 Assisted | L3 Unattended |
|---|---|---|---|
| **Posture** | discovery + triage | propose changes | autonomous land |
| **Writes?** | no — report only | yes, in a worktree | yes, allowlisted classes |
| **Permission mode** | `plan` or `dontAsk` + read allowlist | `dontAsk` + narrow allowlist, or `auto` | `bypassPermissions` **in a container** |
| **Required guardrails** | bounded scope, kill switch | + guard command, + worktree, + escalation | + denylist, + isolation boundary, + budget cap |
| **Lands by** | a human reads the report | a human approves the PR (or `fleet-ops`) | the loop, inside its boundary |
| **Blast radius** | zero (no writes) | one PR, reviewable | bounded by the denylist + container |

---

## How each tier maps to a permission mode

Claude Code has six permission modes. Loops use four of them:

| Mode | Behaviour | Loop tier |
|---|---|---|
| `plan` | read/explore only; cannot edit | L1 (strictest) |
| `dontAsk` | auto-**denies** anything not pre-approved; read-only Bash always allowed; fully non-interactive | L1 / L2 (**recommended default for workers**) |
| `auto` | a classifier model gates each unresolved action; "trust the direction" autonomy | L2 (long runs) |
| `acceptEdits` | in-scope edits + common fs commands auto-approved; other Bash needs an allow rule | L2 (edit-heavy, known command set) |
| `bypassPermissions` | no gates at all | L3 — **only** inside an isolated container/VM without internet |

`default` (prompt each action) is interactive — not for unattended loops.
`acceptEdits` is the middle option when the command set is known.

### Why `dontAsk` is the workhorse for L1/L2 workers

`dontAsk` is fully non-interactive (it never prompts; it auto-denies the unknown), so it
runs anywhere — no container required — and read-only Bash is always allowed. Pair it
with a **narrow** `permissions.allow` list (`Bash(npm test)`, `Bash(git status)`) and you
get a worker that can do exactly its job and nothing else. This is the safe default for
headless loop workers.

---

## The headless-profile table (what a `claude -p` worker should use)

The loop's *maker* runs are headless `claude -p` sessions. Pick the least privilege that
still lets the job run:

| Profile | Behaviour | Use for |
|---|---|---|
| `--permission-mode dontAsk` + curated `permissions.allow` | auto-denies anything not pre-approved; read-only Bash allowed; non-interactive | **locked-down workers (recommended default)** |
| `--permission-mode auto` | classifier-gated; configure `autoMode.environment` for your infra. In `-p`, repeated blocks abort the session | long "trust-the-direction" runs |
| `--permission-mode acceptEdits` + allow rules | edits + common fs auto-approved; other Bash needs an allow rule | edit-heavy tasks, known command set |
| `--dangerously-skip-permissions` (= `bypassPermissions`) | no gates; refuses root/sudo; `rm -rf /`\|`~` still circuit-break | **only** in an isolated container/VM/devcontainer without internet |

In **non-interactive `-p` mode** a hard denial **aborts the session** (there's no human
to prompt). So an `auto`-mode worker that hits a wall dies; a `dontAsk` worker with a
correct allowlist never hits one. This is why enumerating permissions beats relying on
the classifier for batch workers.

---

## The cardinal rule: scheduler invokes `claude -p`, not session-spawns-loop

This is the one thing the upstream methodology can't tell you because it isn't grounded
in Claude Code's gate. **An unattended loop must be a scheduler/script that invokes
`claude -p` — not a Claude session that tries to launch the loop.**

Why: the auto-mode classifier evaluates tool calls *inside* an auto-mode session. A
session that tries to spawn a detached `claude -p --permission-mode bypassPermissions`
child is blocked as **Create Unsafe Agents** (an ungated autonomous agent with no human
gate). Two independent fixes, combine for best result:

1. **Move the launch outside the auto-mode session.** A human — or a human-configured
   Task Scheduler / cron / CI runner / plain script — running `claude -p …` is the
   authorizer, with no parent classifier in the loop. Don't run the *orchestrator*
   session itself in auto mode if its job is spawning agents.
2. **Give the child gates instead of bypass.** The denial is about the *ungated*
   property, not headless-ness. A `dontAsk`+allowlist child is gated and runs fine.

> **Subagents can't escalate.** Agent/Task subagents inherit the parent's mode; the
> classifier uses the parent mode and ignores `permissionMode` in subagent frontmatter.
> A full-bypass worker fleet must be the isolated-container path launched *outside* the
> auto-mode session — never an in-session subagent.

---

## The real fork: enumerate vs isolate

When a loop needs real power, there are exactly two legitimate shapes. Reaching for
`bypassPermissions` on the host *to avoid enumerating permissions* is precisely the
pattern the classifier blocks.

| | **Enumerate** | **Isolate** |
|---|---|---|
| Shape | `dontAsk` + a curated allowlist | container/VM + `bypassPermissions` |
| Runs | anywhere (host, CI, laptop) | only inside the sandbox |
| Safety | bounded by the allowlist | bounded by the container |
| Cost | you list the commands once | you stand up isolation |
| Best for | most loops; CI/PR/dep workers | heavy autonomous refactors, untrusted-input runs |

**Default to enumerate.** Reach for isolate only when the job genuinely needs arbitrary
execution *and* you have a real sandbox (no internet, can't damage the host).

---

## Tier checklist (what `loop-audit` enforces)

- **L1:** bounded `scope` (never `*`), a `kill_switch`, `permission_mode` ∈ {plan,
  dontAsk}, **no** `verify` that writes. Report-only.
- **L2:** all of L1, plus a `verify` gate **and** a `guard` (must-always-pass),
  `worktree: true`, a concrete `escalation:` rule, and a `land_via` (e.g. `fleet-ops`).
- **L3:** all of L2, plus `permission_mode: bypassPermissions` **with** an isolation note
  in `escalation`/scope, a denylist of never-auto-land classes, and a `budget_tokens`
  cap. The audit warns hard if L3 is declared without an isolation boundary.

## See also

- [../../../docs/AUTO-MODE-CLASSIFIER.md](../../../docs/AUTO-MODE-CLASSIFIER.md) — the full two-gate model, classifier categories, legitimate-authorization decision tree.
- [claude-code-loops.md](claude-code-loops.md) — the scheduler/`claude -p` mechanics this tier model runs on.
- [pattern-catalog.md](pattern-catalog.md) — each pattern's recommended starting tier.
