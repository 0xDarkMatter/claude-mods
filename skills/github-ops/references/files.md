# Conventions and Files

The convention each reference enforces with its default, and every file this skill ships with its role.

## Conventions enforced

| Convention | File | Default |
|---|---|---|
| Release strategy | `references/release-strategy.md` | minor on `feat:`, patch on `fix:`-only, major requires approval |
| README intro (2–3 paragraphs) | `references/readme-description.md` | what it is / why it exists / who it's for; concrete, dry, no marketing fluff |
| README as a landing page | `references/readme-landing-page.md` | pick a register first (**Showcase** pitch-forward vs **Reference** usage-forward) and never mix; then section order (benefits before mechanics), ≤ 5-badge row with a shared `labelColor`, features-as-benefits, conditional screenshot in `docs/screenshots/` with alt text + dark variant |
| README Recent Updates style | `references/readme-recent-updates.md` | claude-mods per-version blocks (alternate: flarecrawl table) |
| Repo visibility default | `references/repo-visibility.md` | `--private` unless user says "public" |
| Metadata audit checklist | `references/metadata-checklist.md` | full source-of-truth for mode `audit` |
| Issue operations | `references/issue-ops.md` | view → triage → comment (with preview) → close; closing comments preview-gated |
| PR operations | `references/pr-ops.md` | create (preview body) → review → pre-merge gate → squash by default; branch deletion separate explicit step |

## Files

| File | Role |
|---|---|
| `SKILL.md` | This file — modes, rules, delegation |
| `references/release-strategy.md` | Version bump policy |
| `references/readme-description.md` | 2–3 paragraph README intro — voice, structure, anti-patterns |

| File | Role |
|---|---|
| `references/readme-recent-updates.md` | "Recent Updates" section format + emoji vocabulary |
| `references/repo-visibility.md` | Private-by-default policy |
| `references/metadata-checklist.md` | Audit checklist source of truth |
| `references/issue-ops.md` | Issue operation playbooks (view/triage/comment/create/close) + preview templates |
| `references/pr-ops.md` | PR operation playbooks (create/review/merge) + pre-merge gate + merge-strategy decision tree |
| `scripts/repo-scorecard.sh` | **Capstone audit tool.** Scored, read-only repo-health matrix — orchestrates `check-security-posture.sh` + `check-issues.sh` and adds metadata/release/actions signals into a 0–100 score + grade per repo; `--org` for a fleet matrix + roll-up; `--min-score N` to gate CI; `--json` envelope. Surfaces top-3 fixes per repo. Never mutates |
| `scripts/check-issues.sh` | Surface open issues you may not have seen (externally-authored + stale) for a repo or remote. Read-only `gh issue list`; flags author≠owner and untouched-for-N-days |
| `scripts/check-security-posture.sh` | Read-only repo security-posture auditor. Per-feature checklist (Dependabot alerts/updates, secret scanning + push protection, code scanning, private vuln reporting, SECURITY.md, branch protection), visibility-aware severity, open-alert exposure where a scanner is on, `--org` fleet sweep. Emits enable commands as text — never applies a change |
| `assets/SECURITY.md.template` | Copy-ready vulnerability-disclosure policy (supported versions, private reporting via GitHub PVR, response SLAs, scope, safe harbor) — what `check-security-posture.sh` points at when SECURITY.md is absent |
