---
name: push-gate
description: "Pre-push safety gate for any git push to a remote (GitHub, GitLab, Bitbucket, self-hosted). Runs gitleaks + regex-layer secret scan, forbidden-file check, divergence check, size warning, and requires explicit confirm before pushing. Refuses on any secret hit. Triggers on: push to origin, push to github, push to remote, git push, can we push, safe to push, ready to push, pre-push check, push-gate."
license: MIT
allowed-tools: "Read Bash Glob Grep"
metadata:
  author: claude-mods
  related-skills: git-ops, security-ops
---

# Push Gate

Formalised pre-push safety check. Runs before **every** `git push <remote>` where the remote is not a local file path. Refuses on secret hits; warns on size/forbidden-file; confirms intent before pushing.

Use this skill whenever the user asks to push, or before Claude runs `git push` to any remote. Complements `git-ops` (which handles the push itself) — this is the gate that runs immediately before.

## Hard rules

1. **Gitleaks is a required dependency.** If not installed, emit the install instructions and refuse. Do not silently fall back to regex-only.
2. **Any secret-scanner hit ⇒ refuse.** No bypass flag. Force the user to rewrite history and re-invoke the gate.
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
Step 6  →  Secret scan  ────────┐
Step 7  →  Forbidden-file scan  │ refuse on any hit
Step 8  →  Size advisory        │
Step 9  →  Explicit confirm     │
Step 10 →  git push <remote> <branch>
Step 11 →  Post-push verify (ls-remote matches pushed SHA)
```

## Invocation

```bash
bash .claude/skills/push-gate/scripts/preflight.sh <remote> <branch>
```

The script prints a structured report and exits with:

| Exit code | Meaning | What Claude does |
|---|---|---|
| 0 | All gates passed; ready for push | Ask user to confirm, then `git push <remote> <branch>` |
| 1 | Secret-scanner hit | Report to user; refuse; suggest `git filter-repo` / BFG |
| 2 | Forbidden file added (.env, key files, worktree paths, etc.) | Report; refuse |
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

Both secret layers must pass: gitleaks detects known token formats with a maintained corpus; the regex layer catches generic `password = "..."` / DSN / connection-string patterns that gitleaks may miss. See `references/secret-patterns.txt` for the regex corpus.

## Trigger phrases

| User intent | Triggers |
|---|---|
| Direct | "push to origin", "push to github", "push to remote", "git push" |
| Question | "can we push?", "safe to push?", "ready to push?" |
| Explicit | `/push-gate`, "run push-gate" |

Claude should invoke `scripts/preflight.sh` on any of these. Do not invoke on local pushes (`git push <path>` or `git push .`) — those are the `updateInstead` pattern for cross-worktree landings and don't leave the host.

## False-positive handling

The regex layer filters common false positives automatically (env-var references, shell fallbacks, placeholders with `...`). Gitleaks has its own `.gitleaksignore` file mechanism — add entries there for confirmed-safe findings, committed at repo root. The skill **will not** offer an inline bypass.

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
| `assets/` | (empty; reserved for future report templates) |
