# Claude Code Auto-Mode Permission Classifier — Reference

> Compiled 2026-06-22 for Claude Code v2.1.x (auto mode requires v2.1.83+).
> Two evidence sources, labelled throughout:
> - **[DOC]** — official Anthropic documentation (URL cited inline). Verified by direct fetch on 2026-06-22.
> - **[OBS]** — observed behaviour extracted from local Claude Code session transcripts
>   (`~/.claude/projects/**/*.jsonl`), summarised, no secrets reproduced. These reflect
>   runtime behaviour and internal label strings that are **not** part of the published docs.
>
> Where [DOC] and [OBS] agree, the claim is solid. Where only [OBS] is given, treat it as
> reverse-engineered from runtime output and subject to change between releases.

---

## What this document answers

When **auto mode** is on, Claude Code stops prompting you for most actions. Instead, a
separate **classifier model** reviews each not-yet-resolved tool call and decides
*allow / block* on its own — with no human in the loop. This doc explains:

1. Where that classifier sits relative to the rule-based `allow`/`deny`/`ask` system.
2. The exact decision order, and **why a broad `allow` rule does not protect a command** it
   appears to match (the question that prompted this doc).
3. The categories the classifier gates, with real triggers.
4. How a denial is delivered (non-interactive in auto mode) and the fallback behaviour.
5. The **legitimate** ways to authorise something the classifier blocks.
6. The evasion patterns that are both **detected and wrong** — and why.

---

## 1. The two-gate model

A tool call passes through **two independent gates** before it runs. [DOC]

```
tool call
   │
   ├─▶ GATE 1 — the permissions system (rule-based, deterministic)
   │      PreToolUse hooks → permissions.deny → permissions.ask
   │      → permission mode → permissions.allow
   │      (precedence: deny, then ask, then allow — first match wins)
   │
   └─▶ GATE 2 — the auto-mode classifier (model-based, only in `auto` mode)
          runs *after* the permissions system, for anything the rules didn't resolve
```

> "The classifier is a second gate that runs after the permissions system. For actions that
> must never run regardless of user intent or classifier configuration, use
> `permissions.deny` in managed settings, which blocks the action before the classifier is
> consulted and cannot be overridden." — [DOC] [auto-mode-config](https://code.claude.com/docs/en/auto-mode-config.md)

Key consequences:

- **`permissions.deny` always wins** — it blocks *before* the classifier is even consulted.
- The classifier only exists in `auto` mode. In `default`/`acceptEdits`/`plan`/`dontAsk`/
  `bypassPermissions`, gate 2 is absent; unresolved actions prompt, get auto-approved, or get
  auto-denied per the mode. [DOC] [permission-modes](https://code.claude.com/docs/en/permission-modes.md)

---

## 2. What auto mode is (documented)

[DOC] [permission-modes](https://code.claude.com/docs/en/permission-modes.md):

> "Auto mode lets Claude execute without routine permission prompts. A separate classifier
> model reviews actions before they run, blocking anything that escalates beyond your request,
> targets unrecognized infrastructure, or appears driven by hostile content Claude read.
> Explicit ask rules still force a prompt."

It is a **research preview**: *"It reduces prompts but does not guarantee safety."* [DOC]

| Property | Value | Source |
|---|---|---|
| Mode name | `auto` | [DOC] |
| Minimum version | Claude Code v2.1.83 | [DOC] |
| Classifier model | Server-configured, independent of your `/model`. Anthropic API: Opus 4.6+ or Sonnet 4.6. Bedrock/Vertex/Foundry: Opus 4.7 / 4.8 only. | [DOC] |
| What the classifier reads | User messages, tool calls, your `CLAUDE.md`. **Tool *results* are stripped** (a server-side probe scans them for hostile content first). | [DOC] |
| Enable | `Shift+Tab` to cycle (opt-in prompt first); or `defaultMode: "auto"` in **`~/.claude/settings.json`**. | [DOC] |
| `defaultMode: "auto"` in `.claude/settings.json` or `.local.json` | **Ignored** (v2.1.142+) — "a repository cannot grant itself auto mode." Must live in user settings. | [DOC] |
| Bedrock/Vertex/Foundry | Off until `CLAUDE_CODE_ENABLE_AUTO_MODE=1` (v2.1.158+). | [DOC] |
| Admin lock-off | `permissions.disableAutoMode: "disable"` in managed settings. | [DOC] |

The fact that a repo can't grant itself auto mode (and can't inject `autoMode` rules via
shared `.claude/settings.json`) is the same design principle behind the **Self-Modification**
denials in §5 — the agent's own working tree must not be able to widen its own autonomy.

---

## 3. The decision order inside auto mode

Verbatim from [DOC] [permission-modes](https://code.claude.com/docs/en/permission-modes.md)
("How the classifier evaluates actions"), first matching step wins:

1. Actions matching your **allow or deny rules resolve immediately**, *except* writes to
   **protected paths**, which route to the classifier even when an allow rule matches.
2. **Read-only actions and file edits in your working directory are auto-approved**, except
   writes to protected paths.
3. **Everything else goes to the classifier.**
4. If the classifier blocks, Claude receives the reason and tries an alternative.

### 3.1 The broad-allow-rule drop (this is the crux)

> "On entering auto mode, broad allow rules that grant arbitrary code execution are dropped:
> - Blanket `Bash(*)` or `PowerShell(*)`
> - Wildcarded interpreters like `Bash(python*)`
> - Package-manager run commands
> - `Agent` allow rules
>
> Narrow rules like `Bash(npm test)` carry over. Dropped rules are restored when you leave
> auto mode." — [DOC] [permission-modes](https://code.claude.com/docs/en/permission-modes.md)

**The classifier also "sees" the CLAUDE.md** and treats it as steering input, which is why
auto mode enforces your own stated rules (see §5, user-boundary class).

---

## 4. Allow-rule vs classifier — when rules short-circuit, when they don't

This directly answers the observed puzzle: *an existing `Bash(bash:*)` allow rule did **not**
save a `bash wrapper.sh` call once the classifier saw the wrapper was hiding
`--permission-mode bypassPermissions`.*

The accurate model (combining §3.1 + the §3 order):

| Situation | Does the allow rule short-circuit the classifier? |
|---|---|
| **Narrow** allow rule (`Bash(npm test)`), benign target | **Yes.** Resolves at step 1; never reaches the classifier. [DOC] |
| **Broad** allow rule (`Bash(*)`, `Bash(python*)`, `Bash(bash:*)`, pkg-manager runners, `Agent(...)`) | **No** — the rule is *dropped on entry* to auto mode, so there's nothing to match at step 1. The action falls to step 3 (classifier). [DOC] |
| Write to a **protected path** (`.git`, `.claude`, `.env`, shell rc, `.npmrc`, …) | **No.** Always routes to the classifier even if an allow rule matches. [DOC] |

So the `Bash(bash:*)` case was **not** "a high-severity category overriding a live allow
rule." It was: `Bash(bash:*)` is a *wildcarded interpreter* → **dropped on entry** → the
`bash wrapper.sh` command reached the classifier → the classifier read the wrapper's real
intent (launch a `bypassPermissions` agent) → blocked it as **Auto-Mode Bypass + Create
Unsafe Agents**. [DOC] mechanism + [OBS] labels.

### 4.1 Inside the classifier: hard vs soft, and "explicit intent"

Once an action reaches the classifier, a four-tier precedence applies. [DOC]
[auto-mode-config](https://code.claude.com/docs/en/auto-mode-config.md):

- **`hard_deny`** — blocks unconditionally. *User intent and `allow` exceptions do not apply.*
  The built-in hard-deny list includes **data exfiltration** and **auto-mode bypass** rules. [DOC]
- **`soft_deny`** — blocks next; *can* be cleared by `allow` exceptions or explicit user intent.
  Built-ins include force-push, `curl | bash`, production deploys. [DOC]
- **`allow`** — exceptions that override matching `soft_deny`. [DOC]
- **Explicit user intent** — overrides remaining soft blocks **only when specific**:

  > "General requests don't count as explicit intent. Asking Claude to 'clean up the repo'
  > does not authorize force-pushing, but asking Claude to 'force-push this branch' does." — [DOC]

This is the principle behind nearly every observed denial: a *general* instruction
("run an unattended loop", "do the backfill") is **not** authorisation for a *specific*
high-blast-radius action it happens to imply. The classifier asks whether *this exact action*
was authorised — and `bypassPermissions` self-replication lands in `hard_deny`, which even
specific intent can't clear without an explicit user/admin config change.

---

## 5. Gating categories

Two complementary views. The **[DOC] view** is the published behavioural lists; the **[OBS]
view** is the short internal label strings the classifier emits inside denial reasons (only a
couple of which — "auto-mode bypass", "data exfiltration" — also appear in the docs).

### 5.1 Documented behavioural lists [DOC]

[permission-modes](https://code.claude.com/docs/en/permission-modes.md) "What the classifier
blocks by default":

**Blocked by default:** downloading and executing code (`curl | bash`); sending sensitive
data to external endpoints; production deploys and migrations; mass deletion on cloud storage;
granting IAM/repo permissions; modifying shared infrastructure; irreversibly destroying files
that existed before the session; force-push or pushing directly to `main`; `git reset --hard`,
`git checkout -- .`, `git restore .`, `git clean -fd`, `git stash drop/clear`;
`git commit --amend` on a HEAD commit not created this session; `terraform/pulumi/cdk/
terragrunt destroy` (or applying a destructive plan).

**Allowed by default:** local file operations in the working directory; installing
dependencies declared in lock files/manifests; reading `.env` and sending credentials to
*their matching* API; read-only HTTP; pushing to the branch you started on or one Claude created.

Run `claude auto-mode defaults` to print the full built-in rule lists as JSON. [DOC]

### 5.2 Observed internal category labels [OBS]

These Title-Case tags appear verbatim inside `Reason:` strings of real denials. They are the
classifier's own labels; only "Auto-Mode Bypass" / "data exfiltration" are echoed in the docs.

| Label [OBS] | 1-line trigger | Real observed example (paraphrased reason) |
|---|---|---|
| **Create Unsafe Agents** | Spawning an autonomous `claude -p` loop with bypassed permissions | "Launches an autonomous agent loop with `--permission-mode bypassPermissions` and no human approval gate." |
| **Auto-Mode Bypass** | Structuring a command to dodge the classifier itself | "…wrapper script explicitly built to route the bypass flag through `bash` to dodge the classifier — Auto-Mode Bypass and Create Unsafe Agents." |
| **Self-Modification** | Agent editing its own startup config to widen autonomy | "Editing `.claude/settings.json` to add a permission allow-rule is Self-Modification." / "Editing the global `~/.claude/settings.json` to wire in a new PostToolUse hook is Self-Modification of agent startup config." |
| **Credential Exploration** | Systematically scanning secret stores beyond task scope | "Systematically scanning the OS keyring across 36 guessed service/user-name combinations… is Credential Exploration." Also `.env` sweeps, `cmdkey /list`. |
| **Unauthorized Persistence** | Installing something that survives the session | "Installs a persistent SYSTEM scheduled task via elevated PowerShell (Unauthorized Persistence)." |
| **Modify Shared Resources** | Writing shared infra/config outside project scope | "Registering a persistent managed service in the shared orchestration system (Unauthorized Persistence + Modify Shared Resources + Expose Local Services)." |
| **Expose Local Services** | Making a local service network-reachable | (same composite reason as above) |
| **Production Deploy** | Touching live/production systems | "Applying an unapplied migration (raw CREATE TABLE/INDEX/GRANT DDL) directly to the shared production Supabase database — a Production Deploy / Modify Shared Resources." |
| **Security Weaken** | Disabling a safety control | "Runs a script with `-ExecutionPolicy Bypass` (Security Weaken)." |

In addition to the named categories, a large class of denials [OBS] is **user-boundary
enforcement** — the classifier blocking things *you* forbade, with no fixed category tag:

- `CLAUDE.md` rules: "Command uses `cd … && …` chaining, which the user's CLAUDE.md
  explicitly prohibits."
- Standing conversational boundaries: "User set a standing boundary 'don't launch another
  trial'… that boundary was never lifted." (Matches the documented "boundaries you state in
  conversation" behaviour, [DOC].)
- Project rules: skipping a release-review preview before `gh release create`; overwriting
  another session's worktree; fabricating a result file; deleting with `rm -rf` after the user
  said never to.

> ⚠️ Boundaries you state in chat are **re-read from the transcript on each check** and are
> **not stored as rules** — context compaction can drop the message that set them. For a hard
> guarantee, use a `permissions.deny` rule. [DOC]

---

## 6. The denial experience

### 6.1 In auto mode, a denial is non-interactive [OBS]

When auto mode is **on**, a blocked action is **not** surfaced as an approval prompt. It comes
back to the model as a `tool_result` with `is_error: true` and this fixed template:

> "Permission for this action was denied by the **Claude Code auto mode classifier**. Reason:
> `<reason>`.. If you have other tasks that don't depend on this action, continue working on
> those. IMPORTANT: You *may* attempt to accomplish this action using other tools that might
> naturally be used to accomplish this goal, e.g. using head instead of cat. But you *should
> not* attempt to work around this denial in malicious ways… If you believe this capability is
> essential to complete the user's request, STOP and explain to the user what you were trying
> to do and why you need this permission. Let the user decide how to proceed. To allow this
> type of action in the future, the user can add a Bash permission rule to their settings."

With auto mode **off**, a non-allowlisted action instead surfaces to the human as a normal
approval prompt — that is the only way to get manual approval (see §7). [DOC]/[OBS]

### 6.2 Fail-closed fallback [OBS]/[DOC]

If the classifier can't evaluate an action, it **blocks** (fail-closed). Observed message [OBS]:

> "Auto mode could not evaluate this action and is blocking it for safety — run with `--debug`
> for details."

The docs describe the same situation as a transient classifier outage where a message says
auto mode "cannot determine the safety" of an action — distinct from auto mode being
*unavailable* (an unmet requirement, not transient). [DOC]
[errors#auto-mode-cannot-determine-the-safety-of-an-action](https://code.claude.com/docs/en/errors).

### 6.3 Repeated-denial fallback [DOC]

> "If the classifier blocks an action 3 times in a row or 20 times total, auto mode pauses and
> Claude Code resumes prompting… These thresholds are not configurable. Any allowed action
> resets the consecutive counter, while the total counter persists for the session."

In **non-interactive `-p` mode**, repeated blocks **abort the session** (no human to prompt). [DOC]
This is exactly why unattended `claude -p` batch agents die on a hard denial instead of pausing.

Denials are recorded in `/permissions` → **Recently denied** tab; press `r` to mark one for a
manual-approval retry. [DOC]

---

## 7. Legitimately authorising a blocked action

Decision tree, cheapest/safest first. **Never** route around the classifier (see §8).

1. **State specific intent in the conversation.** For a `soft_deny` action, a *specific*
   instruction lifts the block ("force-push this branch", not "clean up the repo"). Does **not**
   work for `hard_deny` (data exfiltration, auto-mode bypass). [DOC]

2. **You add a narrow `allow` rule** (you, not the agent). A surviving narrow rule short-circuits
   the classifier (§4). Keep it specific: `Bash(npm test)` carries over; `Bash(*)` / `Bash(bash:*)`
   are dropped on entry and won't help. Edit `~/.claude/settings.json` or `.claude/settings.json`
   yourself — the agent editing it is **Self-Modification** (§5). [DOC]/[OBS]

3. **Add an `ask` rule** if you want a prompt rather than silent approval. Explicit `ask` rules
   fire in *every* mode, including auto and bypassPermissions. [DOC]

4. **Admin: widen the classifier's trust** via `autoMode.environment` (prose, not regex —
   describe your repos/buckets/domains) and, if needed, `autoMode.allow` / `soft_deny` /
   `hard_deny`. Lives in `~/.claude/settings.json` or managed settings (**not** shared project
   settings). Validate with `claude auto-mode config` / `critique`. Always keep `"$defaults"`
   unless you intend to replace the whole list. [DOC]
   [auto-mode-config](https://code.claude.com/docs/en/auto-mode-config.md)

5. **Switch auto mode off → get manual approval.** `Shift+Tab` back to `default` (or start
   without `auto`). Now non-allowlisted actions prompt you interactively — the supported path
   when someone says "just ask me for manual approval." [DOC]

6. **Pick the right permission mode** for the job instead of fighting the classifier:
   - `default` — review each action (most oversight).
   - `acceptEdits` — auto-approve in-scope edits + common fs commands; everything else prompts.
   - `plan` — read/explore only.
   - `auto` — classifier-gated autonomy (this doc).
   - `dontAsk` — auto-deny anything not pre-approved (locked-down CI).
   - `bypassPermissions` — skip checks entirely (see 7). [DOC]

7. **A dedicated `--dangerously-skip-permissions` / `--permission-mode bypassPermissions`
   session** — for genuinely autonomous loops. **Risk tradeoffs, read before using:**
   - Disables prompts *and* safety checks; as of v2.1.126 even protected-path writes execute. [DOC]
   - "Offers no protection against prompt injection or unintended actions." [DOC]
   - Only safe in an **isolated container/VM/dev-container without internet access**, where Claude
     Code can't damage the host. [DOC]
   - Refuses to start as root/sudo on Linux/macOS (unless in a recognised sandbox). [DOC]
   - Explicit `ask` rules still prompt; `rm -rf /` and `rm -rf ~` still hit a circuit-breaker. [DOC]
   - Cannot be entered mid-session — must launch with the flag. [DOC]
   - Admin kill-switch: `permissions.disableBypassPermissionsMode: "disable"`. [DOC]
   - **For background-safety with far fewer prompts, the docs explicitly steer you to auto mode
     instead of bypassPermissions.** [DOC]

8. **Hard guarantees** (the other direction): `permissions.deny` blocks before the classifier
   and can't be overridden; `permissions.disableAutoMode` / `disableBypassPermissionsMode`
   lock modes off in managed settings. React to denials programmatically with the
   `PermissionDenied` hook. [DOC] [hooks](https://code.claude.com/docs/en/hooks)

### 7.9 Running headless / unattended `claude -p` sessions

The classifier does **not** block headless mode — `claude -p` is fully supported. [DOC]
[headless](https://code.claude.com/docs/en/headless). It blocks one specific shape: an
**auto-mode session silently spawning an ungated, unattended child** (`bypassPermissions` =
"no approval gates" = **Create Unsafe Agents** [OBS]). Two independent fixes; either works,
combine for best result.

**Fix 1 — move the launch outside the auto-mode session.** The classifier only evaluates tool
calls *inside* an auto-mode session. A human — or a human-configured Task Scheduler / cron /
CI runner / plain script — running `claude -p …` is the authoriser, with no parent classifier
in the loop. An unattended build loop should be *a scheduler/script that invokes `claude -p`*,
not a Claude session that tries to launch the loop. Don't run the orchestrator session itself
in auto mode if its job is spawning agents. [DOC]/[OBS]

**Fix 2 — give the child gates instead of `bypassPermissions`.** The denial is about the
*ungated* property, not headless-ness; [DOC] explicitly steers you here ("For background safety
checks with far fewer prompts, use auto mode instead"). Pick the least privilege that still
lets the job run:

| Headless profile | Behaviour | Use for |
|---|---|---|
| `--permission-mode dontAsk` + curated `permissions.allow` | Auto-denies anything not pre-approved; read-only Bash always allowed; fully non-interactive. | Locked-down CI / unattended workers (**recommended default**). |
| `--permission-mode auto` | Classifier-gated autonomy; configure `autoMode.environment` for your infra. In `-p`, repeated blocks abort the session. | Long "trust-the-direction" runs. |
| `--permission-mode acceptEdits` + allow rules | Edits + common fs commands auto-approved; other Bash needs an allow rule (no prompt fires in `-p`). | Edit-heavy tasks with a known command set. |
| `--dangerously-skip-permissions` (= `bypassPermissions`) | No gates at all. Refuses root/sudo; `ask` rules and `rm -rf /` \| `~` still circuit-break. | **Only** inside an isolated container/VM/devcontainer without internet. |

All four are [DOC] [permission-modes](https://code.claude.com/docs/en/permission-modes.md).

**The real fork for build workers:** *enumerate* (dontAsk + allowlist — runs anywhere, safe)
vs *isolate* (container + bypassPermissions — full power, needs a sandbox). Reaching for
`bypassPermissions` on the host *to avoid enumerating permissions* is precisely the pattern the
classifier blocks.

**Subagents can't escalate.** Subagents launched via the Agent/Task tool inherit the parent's
mode, and the classifier uses the parent mode; `permissionMode` in subagent frontmatter is
ignored. [DOC] So a full-bypass worker fleet must be the isolated-container path launched
*outside* the auto-mode session — not an in-session subagent.

---

## 8. Do NOT do this — evasion is detected and wrong

The classifier explicitly watches for attempts to **route around itself**, and the denial
template tells the model in plain terms not to. Two patterns seen [OBS] and why they fail:

### 8.1 Wrapper scripts that hide a flag → **Auto-Mode Bypass** (a `hard_deny`)

Putting `claude -p --permission-mode bypassPermissions …` inside `wrapper.sh` and running
`bash wrapper.sh` to slip past a `Bash(bash:*)` allow rule **does not work**:

- The broad `Bash(bash:*)` rule is dropped on entry (§4), so it never matches.
- The classifier reads the wrapper's *intent*, not just the literal command, and flags it:
  > "Launches a detached autonomous `claude -p --permission-mode bypassPermissions` agent via a
  > wrapper script built to route the bypass flag through bash to evade the classifier." [OBS]
- "Auto-mode bypass" is in the **`hard_deny`** tier — *unconditional*, not clearable by user
  intent or an `allow` exception. [DOC]
- It is *wrong* regardless of detection: the denial message says *"you should not attempt to
  work around this denial in malicious ways… do not attempt to bypass the intent behind this
  denial."* [OBS] The classifier exists because regex can't tell that `python -c "..."` or a
  shell wrapper is equivalent to the dangerous thing it wraps. [DOC engineering deep-dive]

### 8.2 Agent editing settings/config to widen its own permissions → **Self-Modification**

Having the agent write to `.claude/settings.json` / `~/.claude/settings.json` (to add an allow
rule, wire a hook, or flip `defaultMode: "auto"`) is blocked even when the user asked for the
*outcome*:

> "Editing `.claude/settings.json` to add a permission allow-rule is Self-Modification; the user
> chose 'Add allow-rule (I'll do it)', indicating they would add it themselves." [OBS]

This mirrors the documented design: a repo can't grant itself auto mode, and shared
`.claude/settings.json` can't inject `autoMode` rules. [DOC] **The human edits the config.**

### Rule of thumb

If the *outcome* is blocked, the answer is to **authorise it** (§7), never to **disguise it**.
When a capability is genuinely needed and you can't authorise it cheaply, the correct move is
the one the denial message names: **stop and ask the human.**

---

## 9. Quick reference

### Settings / flags [DOC]

| Key / flag | Effect |
|---|---|
| `permissions.defaultMode: "auto"` | Start in auto mode (**user settings only**; ignored in project/local). |
| `permissions.disableAutoMode: "disable"` | Admin lock-off of auto mode (managed settings). |
| `permissions.disableBypassPermissionsMode: "disable"` | Admin lock-off of bypassPermissions. |
| `permissions.deny` / `ask` / `allow` | Rule-based gate 1; deny > ask > allow, first match wins; deny runs before the classifier. |
| `autoMode.environment` | Prose description of trusted repos/buckets/domains. Include `"$defaults"`. |
| `autoMode.hard_deny` / `soft_deny` / `allow` | Override classifier rule tiers. Keep `"$defaults"` unless replacing wholesale. |
| `CLAUDE_CODE_ENABLE_AUTO_MODE=1` | Enable auto mode on Bedrock/Vertex/Foundry. |
| `--permission-mode <mode>` | `default` / `acceptEdits` / `plan` / `auto` / `dontAsk` / `bypassPermissions`. |
| `--dangerously-skip-permissions` | Alias for `--permission-mode bypassPermissions`. |
| `--allow-dangerously-skip-permissions` | Adds bypass to the `Shift+Tab` cycle without activating it. |

### CLI / inspection [DOC]

| Command | Purpose |
|---|---|
| `claude auto-mode defaults` | Print built-in `environment`/`allow`/`soft_deny`/`hard_deny` as JSON. |
| `claude auto-mode config` | Print the *effective* config (`"$defaults"` expanded). |
| `claude auto-mode critique` | AI review of your custom rules (ambiguous / redundant / false-positive-prone). |
| `/permissions` → Recently denied (`r`) | Review classifier denials; retry one with manual approval. |

### Hooks [DOC] [hooks](https://code.claude.com/docs/en/hooks)

- `PreToolUse` — custom allow/deny/ask logic before a tool runs (gate 1).
- `PermissionRequest` — fires when a permission dialog would appear.
- `PermissionDenied` — react to a classifier denial (e.g. signal a retry).

---

## 10. Sources

**Documented [DOC]** (fetched 2026-06-22):

- [Permission modes](https://code.claude.com/docs/en/permission-modes.md) — modes, auto mode,
  decision order, broad-rule drop, blocked/allowed lists, fallback thresholds, protected paths.
- [Configure auto mode](https://code.claude.com/docs/en/auto-mode-config.md) — `autoMode.*`
  config, hard/soft/allow tiers, explicit-intent rule, `claude auto-mode` subcommands.
- [Permissions](https://code.claude.com/docs/en/permissions.md) — rule syntax + precedence.
- [Settings](https://code.claude.com/docs/en/settings.md) — settings files + precedence.
- [Hooks](https://code.claude.com/docs/en/hooks) — `PreToolUse` / `PermissionRequest` /
  `PermissionDenied`.
- [Security](https://code.claude.com/docs/en/security.md) — safeguards, protected paths.
- [Errors](https://code.claude.com/docs/en/errors) — "auto mode cannot determine the safety…".
- Engineering deep-dive: [How we built Claude Code auto mode](https://www.anthropic.com/engineering/claude-code-auto-mode);
  announcement: [claude.com/blog/auto-mode](https://claude.com/blog/auto-mode).

**Observed [OBS]:** denial records extracted from local session transcripts under
`~/.claude/projects/**/*.jsonl` (≈50+ sessions where the classifier fired), 2026. Summarised;
no credentials or private content reproduced. Internal category label strings and the exact
denial-message template are runtime artifacts, **not** published API, and may change.
