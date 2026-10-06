---
name: push-preflight
description: "Secret-scans the commits a git push would send (gitleaks + regex layer; never history), then checks clean tree, forbidden files and fast-forward, with size and open-issue advisories. Refuses on any secret hit, no bypass. Triggers on: push to origin, push to github, push to remote, git push, can we push, safe to push, ready to push, pre-push check, /push-preflight (formerly push-gate)."
license: MIT
allowed-tools: "Read Bash Glob Grep"
metadata:
  author: claude-mods
  related-skills: git-ops, security-ops
---

# Push Preflight

Formalised pre-push safety check. Runs before **every** `git push <remote>` where the remote is not a local file path. Refuses on secret hits; warns on size/forbidden-file; confirms intent before pushing.

Use this skill whenever the user asks to push, or before Claude runs `git push` to any remote. Complements `git-ops` (which handles the push itself) — this is the gate that runs immediately before.

**Why the name.** Formerly `push-gate`. It runs six checks (secret scan, clean tree, forbidden files, fast-forward, size advisory, open-issue advisory), so `secret-scan` would undersell it, and mislead: it scans only the commits being pushed, never history (that is `security-ops`). The name matches `scripts/preflight.sh`. The secret scan leads the description because the description, not the name, is what selects the skill.

## Hard rules

1. **Gitleaks is a required dependency.** If not installed, emit the install instructions and refuse. Do not silently fall back to regex-only.
2. **Any secret-scanner hit ⇒ refuse.** No bypass flag. Confirmed-safe findings go into the committed repo-local allowlists (`.gitleaksignore` for gitleaks, `.push-preflight-allow` for the regex layer — see §False-positive handling), never an inline override. Real secrets force the user to rewrite history and re-invoke the gate.
3. **Never `--force` push.** The gate never passes a force flag. If the user needs to force-push, that's a separate conversation with explicit authorization.
4. **Never `--no-verify`.** Don't skip hooks.
5. **Working tree must be clean.** Refuse on dirty tree (uncommitted work could be accidentally stashed into the push flow).
6. **Remote must be named.** Refuse if `git push` is called without an explicit remote and branch.

## Workflow

```
Step 1  →  Identify remote + branch
Step 2  →  git fetch <remote>
Step 3  →  Verify working tree clean
Step 4  →  Compute pending commits (count + list)
Step 5  →  Check divergence (non-ff ⇒ require user to rebase first)
Step 6  →  Secret scan  ────────┐  gitleaks honours .gitleaksignore,
                                │  regex layer honours .push-preflight-allow
Step 7  →  Forbidden-file scan  │ refuse on any hit
Step 8  →  Size advisory        │
        →  Open-issue advisory (github-ops; informational, never gates)
Step 9  →  Explicit confirm     │
Step 10 →  git push <remote> <branch>
Step 11 →  Post-push verify (ls-remote matches pushed SHA)
```

## Invocation

```bash
# From the repo root (most common)
bash .claude/skills/push-preflight/scripts/preflight.sh <remote> <branch>

# When calling from another skill with a different cwd (e.g. github-ops)
bash $HOME/.claude/skills/push-preflight/scripts/preflight.sh --cwd <repo-root> <remote> <branch>
```

`--cwd` must precede the positional arguments. When omitted, the script operates against `$PWD`.

The script prints a structured report and exits with:

| Exit code | Meaning | What Claude does |
|---|---|---|
| 0 | All gates passed; ready for push | Ask user to confirm, then `git push <remote> <branch>` |
| 1 | Secret-scanner hit | Report to user; refuse; suggest `git filter-repo` / BFG |
| 2 | Forbidden file added (.env, key files, `.claude/settings.local.json`, worktree paths, etc.) | Report; refuse |
| 3 | Dirty working tree | Report; ask user to commit or stash first |
| 4 | Non-ff divergence | Report; ask user to rebase or merge first |
| 5 | Missing dependency (gitleaks) | Report install instructions; refuse |
| 6 | No remote specified / unknown remote | Report; ask for clarification |

## Dependencies

| Tool | Purpose | Install |
|---|---|---|
| **gitleaks** (required) | Secret detection with maintained rule corpus | Windows: `scoop install gitleaks` or `winget install gitleaks.gitleaks` / macOS: `brew install gitleaks` / Linux: `apt install gitleaks` or binary from https://github.com/gitleaks/gitleaks/releases |
| **ripgrep** (required) | Regex fallback layer + forbidden-file scan | Usually pre-installed; `winget install BurntSushi.ripgrep.MSVC` / `brew install ripgrep` |
| **git** ≥ 2.30 | Core operations | Standard |

Both secret layers must pass: gitleaks detects known token formats with a maintained corpus; the regex layer catches generic `password = "..."` / DSN / connection-string patterns that gitleaks may miss. See `references/secret-patterns.txt` for the regex corpus. Gitleaks runs with `references/gitleaks-config.toml` (default rule set + an allowlist for public-by-design tokens, e.g. Mapbox `pk.*`); if that file is absent, the scan falls back to gitleaks' built-in default config.

## Trigger phrases

| User intent | Triggers |
|---|---|
| Direct | "push to origin", "push to github", "push to remote", "git push" |
| Question | "can we push?", "safe to push?", "ready to push?" |
| Explicit | `/push-preflight`, "run push-preflight" (formerly `push-gate`) |

Claude should invoke `scripts/preflight.sh` on any of these. Do not invoke on local pushes (`git push <path>` or `git push .`) — those are the `updateInstead` pattern for cross-worktree landings and don't leave the host.

## False-positive handling

Both secret layers have a repo-local, **committed** allowlist. The gate still refuses any hit not explicitly allowed, and the skill **will not** offer an inline bypass — a confirmed-safe finding earns a reviewed entry in the repo, not a one-off override.

| Layer | Allowlist file (repo root) | Entry format |
|---|---|---|
| gitleaks | `.gitleaksignore` | gitleaks fingerprint (`commit:file:rule:line`) |
| regex | `.push-preflight-allow` | `<repo-relative-path>:<line-regex>` |

The regex layer also drops common false positives automatically (env-var references, shell fallbacks, placeholders with `...`) before the allowlist is consulted.

**Legacy name `.pushgate-allow`** (from the `push-gate` era) is still read, with a one-line deprecation notice on stderr. If both files exist, their entries are **combined**: each is a reviewed, committed decision, so a half-finished migration never starts refusing pushes that passed before. Migrate with `git mv .pushgate-allow .push-preflight-allow` (or move the entries across) and commit.

`.push-preflight-allow` rules:

- One entry per line; `#` comments allowed. **Each entry must carry a reason comment directly above it** — the scanner warns when one is missing.
- Entries split on the **first** `:` — a repo-relative path (forward slashes, no `:` in the path), then a Rust-regex matched against the added line's full content. No line numbers anywhere: they drift on every edit above them; a content anchor does not.
- An entry suppresses hits **only in that exact file**. Every other hit still refuses.
- On refusal, the scanner prints a ready-made anchored entry per hit — copy it under a reason comment, commit, and re-run the gate.
- Entries whose file is gone, or whose regex no longer matches any line of that file at the branch tip, are reported as **stale** (warning, non-gating) — prune them.
- The gate's clean-tree rule (hard rule 5) means the file is always committed by the time it is consulted — an uncommitted allowlist edit fails Step 3 before it can suppress anything.

Example:

```
# reason: test fixture — wire-snapshot key exercised by MCP wire tests, not a credential
packages/mcp/test/client.test.ts:^  apiKey: "wire-snapshot-key",$
```

## Not in scope

- Release automation (changelog, tagging, version bumps) — that's `ci-cd-ops` / `git-ops` territory.
- Full security audit — that's `security-ops` (broader SAST + dep scanning).
- Force-push / history rewriting — intentionally excluded; requires explicit out-of-band authorization.
- Signed-commit verification — add later if needed.

## Files

| File | Role |
|---|---|
| `SKILL.md` | This file — workflow + rules |
| `scripts/preflight.sh` | Main orchestration (Steps 1–8) |
| `scripts/scan-secrets.sh` | Gitleaks + regex layer (Step 6) |
| `references/secret-patterns.txt` | Regex corpus + false-positive filter words |
| `references/gitleaks-config.toml` | Gitleaks config: default rules + public-token allowlist (used by `scan-secrets.sh` when present) |
| `tests/run.sh` | Offline behavioural self-test for the secret scanner (planted secrets, FP filter, allowlist, stale entries, legacy allowlist name) |
| `assets/` | (empty; reserved for future report templates) |

Per-repo (not shipped with the skill): `.gitleaksignore` and `.push-preflight-allow`, committed at the scanned repo's root — see §False-positive handling.
