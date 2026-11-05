# Read-Only Auditors

The scorecard, the open-issue checker and the security-posture auditor in full, and the audit checklist rows they roll up. All three are strictly read-only.

## `repo-scorecard.sh`

**Headline: `scripts/repo-scorecard.sh` — one command for a scored repo/fleet health report.** It orchestrates the two read-only auditors (`check-security-posture.sh` + `check-issues.sh`) and adds metadata / release / actions signals, rolling everything into a single **0–100 score + letter grade** per repo, and a **matrix + roll-up** across an org. Reach for it first; drop to the manual checklist below only when you need a specific row the scorecard doesn't surface.

```bash
bash scripts/repo-scorecard.sh --repo 0xDarkMatter/flarecrawl     # single repo: score + dimensions + top 3 fixes
bash scripts/repo-scorecard.sh --org 0xDarkMatter                 # fleet matrix + roll-up (avg/median/worst, fleet open-alert total)
bash scripts/repo-scorecard.sh --org 0xDarkMatter --min-score 75  # CI gate: exit 10 if ANY repo scores < 75
bash scripts/repo-scorecard.sh --repo <o>/<r> --json | jq '.data[0].top_fixes'
```

Five weighted dimensions — **security (35)** highest, then **metadata (25)**, **release (15)**, **issues (15)**, **actions (10)**. Each scores its weight in full (ok) / half (warn) / zero (gap **or** unreadable n/a — an unreadable dimension never counts as healthy). Grade: A≥90 B≥75 C≥60 D≥40 F<40. The full rubric is documented in the script header (`--help`). It surfaces the **top 3 fixes per repo**, highest-severity first, each with the exact remediation pointer (e.g. `→ check-security-posture.sh --repo … --commands`, "add CHANGELOG.md", "cut a GitHub release"). Exit `0` healthy · `10` gaps / below `--min-score` · `7` unavailable (graceful) · `5` gh missing · `2` usage. **Strictly read-only** — only GET `gh api` calls + the read-only siblings; the remediation pointers are text, never executed.

## Mode `audit` checklist: GitHub-state and security rows

```
GITHUB STATE CHECKS (skip if no remote)
  [ ] Repo description is set
  [ ] Repo homepage is set (or explicitly N/A)
  [ ] At least 3 topics
  [ ] Topics align with package keywords
  [ ] Default branch is main (not master)
  [ ] Latest tag has a corresponding release
  [ ] Release notes match CHANGELOG entry

SECURITY POSTURE CHECKS (run scripts/check-security-posture.sh — read-only)
  [ ] Dependabot alerts enabled
  [ ] Dependabot security updates enabled
  [ ] Secret scanning + push protection on   (free on public; needs GHAS on private)
  [ ] Code scanning default setup configured  (free on public; needs GHAS on private)
  [ ] Private vulnerability reporting enabled
  [ ] SECURITY.md present (root / .github/ / docs/)
  [ ] Branch protection on the default branch
  [ ] No OPEN dependabot / secret / code-scanning alerts on enabled scanners
```

## Why the landing-page rows are advisory and unscored

The landing-page rows are marked `[~]` because they are **advisory**: they never fail an
audit and never block mode `new`. They are also **not** scored by `repo-scorecard.sh` —
judging "are these bullets benefits" and "does this project have anything to show" needs
reading comprehension the script can't do at fleet scale, and a wrong answer there would
be charged to every repo. See the reference's closing section for the full rationale.

## Open-issue awareness (the blind spot)

You don't see issues other people file — your own you know about; a stranger's bug report from two months ago is the gap. `scripts/check-issues.sh` closes it:

```bash
bash scripts/check-issues.sh --repo 0xDarkMatter/flarecrawl   # one repo
bash scripts/check-issues.sh --remote origin --stale-days 14  # derive from a remote
bash scripts/check-issues.sh --json | jq '.data[] | select(.external)'
```

Exit `0` = nothing you're missing (no open issues, or all are yours and fresh); `10` = external/stale issues present (the things to look at); `7` = unavailable (not a GitHub remote, gh unauthed/offline) — advisory, never a hard failure; `2` usage; `5` gh not installed.

**Wired into the pre-push gate** ([push-preflight](../../push-preflight)): `preflight.sh` calls this in `--advisory` mode as a post-gate step, so every push surfaces unseen external/stale issues for the target remote. It is **read-only, timeout-bounded, and never affects the gate verdict** — silent when gh is absent/unauthed or the remote isn't GitHub. Run it standalone any time, or across repos, to find what you've missed. For acting on what it surfaces (view/triage/comment/close), see `references/issue-ops.md`.

## Security posture (the other blind spot)

GitHub ships a stack of free security features — Dependabot alerts, security updates, secret scanning + push protection (free on **public** repos), code scanning default setup, private vulnerability reporting, branch protection — and most are **off by default**. You don't see the gap until something leaks. `scripts/check-security-posture.sh` audits it, read-only:

```bash
bash scripts/check-security-posture.sh --repo 0xDarkMatter/flarecrawl   # one repo
bash scripts/check-security-posture.sh --remote origin                  # derive from a remote
bash scripts/check-security-posture.sh --org 0xDarkMatter               # fleet sweep + roll-up
bash scripts/check-security-posture.sh --repo <o>/<r> --commands        # copy-paste enable cmds
bash scripts/check-security-posture.sh --repo <o>/<r> --json | jq '.data[]|select(.state=="off")'
```

It prints a per-feature checklist — `✓ on` / `✗ off [severity]` / `— n/a (needs GHAS)` — and, **where a scanner is enabled**, the count + max severity of OPEN alerts (the real exposure, not just the toggle). The alert endpoints degrade gracefully: a `403` (token lacks `security_events`) or `404` (feature off) becomes "n/a — couldn't read", **never a false "0 / secure"**.

**Visibility-aware severity** is the judgment that makes it usable:

- **public** repo → secret scanning, push protection, code scanning are **free** → a gap is a real finding.
- **private** repo *without* Advanced Security → those three need paid GHAS → reported as a **note (n/a)**, not a nag.
- Free-on-any-repo (Dependabot alerts/updates, private vuln reporting, SECURITY.md, branch protection) → always a finding when off.
- Tiers: `critical` (open critical alerts) · `high` (open high alerts; push-protection or Dependabot-alerts off on public/active) · `medium` (secret/code scanning off on public; security-updates off; no branch protection) · `low` (SECURITY.md absent; private vuln reporting off). Full mapping in the script header.

**It never applies a change.** It is strictly read-only (only GET `gh api` calls); the enable commands are **emitted as text** — `gh api -X PUT …` for Dependabot alerts/security-updates/private-vuln-reporting/code-scanning, a `PATCH` body for secret scanning + push protection (push protection requires secret scanning on first), and a pointer to `assets/SECURITY.md.template` for the policy file. **You review and run them yourself**, governed by the same preview discipline as any other repo mutation (hard rule 8 — these change repo settings). `--commands` prints just the enable commands with a `# review before running` banner on stderr.

Exit `0` = posture clean (all applicable features on, no open alerts); `10` = gaps and/or open alerts (a CI/audit step can branch on it); `7` = unavailable (non-github remote, gh unauthed/offline/timeout) — advisory, never a hard failure; `2` usage; `5` gh not installed. Folds into mode `audit` (see the Security Posture checklist there).
