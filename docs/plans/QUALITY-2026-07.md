# claude-mods Quality & Robustness Plan — 2026-07

Build spec for the fleetflow execution wave. Synthesized from four read-only survey
agents (2× Opus: fleet rationalisation, portability split; 2× Sonnet: context-tax
measurement, robustness triage) run 2026-07-08. Source reports in session
`7ec5760b` task outputs.

Theme: **subtraction and enforcement, not addition.** One new skill total (a router).
Everything else is gates, trims, tests, and truth.

---

## Verified findings the plan rests on

| Finding | Number |
|---|---|
| Context tax (all skill descriptions, always loaded) | 45,946 chars ≈ 11.5k tokens/session; top 18 skills = 43% |
| Natural budget knee | 674→780 chars → hard cap 700 (combined description+when_to_use) |
| Skills without tests | 70/101 (13 HIGH-risk, incl. push-gate) |
| Protocol conformance sample | 3/10 conformant; all 4 non-conformant from 2025-12-21 scaffold batch |
| Fleet family in repo | 6 skills (not 8) — dsp-launch is ~/.claude-only (Axiom-wired), axiom-queue is a symlink INTO the Axiom repo (daemon paused 2026-05-12) |
| Machine coupling in shipped tree | 4 files only (process-compose-ops, portless-ops SKILL.mds; dev-servers.md OK as-is; shell-preference.md needs softening) |
| Monster-file CRITs | Both false-positive-ish: guard comments + section maps EXIST; missing piece is mechanical drift-gates. Do NOT split either file. |
| README drift | line 15 "100"→101, line 116 "97"→101, line 115 commands "(2)"→3. Line 21 correct. (Verified on disk: 101 skills = 102 dirs − _lib; 3 command files.) |
| AGENTS.md | 52 commits stale |
| Doc-drift gate blind spots | doesn't check README lines 15/116, doesn't scan frontmatter related-skills (claude-code-ops still refs dsp-launch) |
| Hook wiring bugs | install.ps1 wires 0 of the 5 security hooks; pre-write-peer-guard + session-touched-ledger written but dark |
| tools/svg-brand-tuner/ | untracked, superseded by svg-studio — safe delete |

Component verdicts (portability agent): description-budget gate STRONG YES ·
skill-telemetry YES as auto-skill extension · push-cadence guard DEFER (SessionStart
advisory if built) · memory-gardener DEFER · release-train DEFER (thin command if ever)
· eval-ops NO.

---

## Phase 0 — Close the loop (orchestrator, manual, BEFORE any fleet)

Nothing lands on an ungated base. ~30 min.

0.1 Delete `tools/svg-brand-tuner/` (untracked; re-verify `git status --short` shows only `??` first).
0.2 Fix README quick counts: line 15 100→101, line 115 (2)→(3), line 116 (97)→(101). Commit `docs: fix README count drift`.
0.3 push-gate preflight → push main (101 commits) → `gh run watch` until green (memory: local gates lie; only CI green counts).
0.4 Commit this plan file to `docs/plans/QUALITY-2026-07.md`.

## Phase 1 — Enforcement gates (build gates BEFORE mass edits)

| WP | What | Brain | Verify |
|---|---|---|---|
| G1 | `validate_description_budget()` in tests/validate.sh: hard cap 700 chars on COMBINED description+when_to_use (PyYAML extraction, sed fallback); catalog soft budget 35,000 warn. Ships in WARN mode; flipped to FAIL by the final commit of Phase 2 after trims land. No exemption mechanism. | Codex | GLM adversarial: feed fixture skills at 699/700/701 chars, multi-line YAML, missing when_to_use |
| G2 | Section-map drift gates: (a) summon tests assert every section named in summon.py docstring has matching `# === X ===` marker; (b) svg-brand-tint-ops tests assert the line-336 section list matches `// === X ===` markers. This is the "mechanical gate that makes a large file safe" agentic-quality requires. NO file splits. | GLM | Codex: mutate a marker in a temp copy, assert gate fails |
| G3 | Extend tests/doc-drift.sh: (a) check README lines 15/115/116-class count sites (grep for `\d+ (specialized )?skills` patterns), (b) scan all skills/*/SKILL.md frontmatter related-skills/depends-on for names not on disk (would have caught the dsp-launch ghost). | Codex | GLM: plant a ghost ref, assert red |
| G4 | repo-doctor refinement: scorer recognizes an existing guard comment + section map + mechanical gate on a >800-line file and downgrades CRIT→INFO (it currently flags the compliant pattern it mandates). | Codex | Sonnet: re-run repo-doctor on this repo, assert 2 CRITs → 0 without file changes |
| G5 | Hook wiring: (a) install.ps1 + install.sh merge the hooks/hooks.json security set into ~/.claude/settings.json on script installs (currently 0 of 5 wired); (b) wire pre-write-peer-guard.sh + session-touched-ledger.sh into hooks/hooks.json (silent-on-clean, meets auto-wire criterion) or explicitly mark experimental. | Codex | Sonnet adversarial: fresh-install simulation into temp CLAUDE_DIR, assert hooks present + idempotent re-run |

## Phase 2 — Consolidation + the great trim

| WP | What | Brain | Verify |
|---|---|---|---|
| T1 | `parallel-ops` router skill (~90-line SKILL.md, no scripts): decision table (native Workflow/Agent → one-off same-provider; fleet-worker → cheap delegation; fleetflow → heterogeneous; loop-ops → recurring; iterate → single-metric session; fleet-ops → landing terminus; spawn disambiguation guard — authoring NOT runtime). Two-axes explainer (spawn-vs-land, inner-vs-outer). Composition chain. + six fleet-family description trims (drafts in fleet report) + fleetflow's inline routing table migrates into router + fix claude-code-ops related-skills (drop dsp-launch) + count bumps 101→102 in README header/AGENTS.md/PLAN.md + README table row. | Sonnet | Codex: cold-agent routing quiz — 8 scenario prompts, assert table routes each to exactly one skill; run doc-drift gate |
| T2 | Description rewrites for remaining top-18 offenders (10 drafts ready in context-tax report: summon 3080→292, pypi-ops, supply-chain-defense, ytdlp-ops, mapbox-ops, isometric-ops, process-compose-ops, ffmpeg-ops, loop-ops, threejs-ops; draft 8 more in same pattern: claude-code-ops, github-ops, portless-ops, mac-ops, prompt-injection-defense, r-ops, repo-doctor, windows-ops — fleet-worker covered by T1). Pattern: one capability clause + flat trigger list, ≤300 chars, combined-field aware. | GLM | Sonnet: trigger-retention check — for each skill, 3 canonical user asks must still lexically hit the new description |
| T3 | Portability sanitization: process-compose-ops SKILL.md (X:\00_Orchestration, -p 8888 → placeholders + "adapt" note), portless-ops SKILL.md (axiom.lab → <your-app>.<your-tld>, one labeled worked example), shell-preference.md (frame author setup as example, not universal). dev-servers.md untouched (already self-describes as template). | GLM | Codex: grep sweep asserts zero unlabeled X:\ / .lab / axiom values in the 3 files |
| T4 | dsp-launch retirement: add to install.ps1/install.sh deprecated_items arrays (`# Superseded by fleet-worker + native background agents (2026-07)`). Do NOT touch axiom-queue anywhere (Axiom-owned symlink — worktree-boundaries). | GLM | orchestrator review (3-line diff) |

Landing order (fleet-ops queue): T1 → T2 → T3 → T4 → flip G1 WARN→FAIL. Run `bash tests/doc-drift.sh` + `bash tests/validate.sh` between each land.

## Phase 3 — Robustness floor

| WP | What | Brain | Verify |
|---|---|---|---|
| R1 | push-gate test suite (highest blast radius untested skill): fixture repo with planted secrets/forbidden files, assert preflight refuses; assert clean repo passes. | Codex | GLM adversarial: 5 secret formats the regex layer should catch |
| R2 | Verifier-wrap suites (cheap wins): claude-api-ops check-model-table --offline, claude-code-ops validate-hooks-json self-test, terraform-ops check-action-refs --offline, process-compose-ops verify-binary. Each = thin tests/run.sh invoking existing verifier offline. | GLM | Codex spot-check 2 of 4 |
| R3 | Security-sensitive suites: security-ops (known-bad fixtures vs grep patterns), pigeon (migration idempotency on throwaway sqlite copy), leveldb-ops (LOCK-removal/copy-safety on fixture profile). | Codex | GLM: mutation test on one pattern per suite |
| R4 | Remaining backlog: container-orchestration (arg parsing dry-run), portless-ops (reset-state dry-run guard), auto-skill (evaluate.sh tracking/reset), python-fastapi-ops (scaffold output+idempotency), python-pytest-ops (overwrite behavior), testing-ops (template-quality example suite). | GLM | Codex spot-check 2 of 6 |
| R5 | Protocol backfill on the 2025-12-21 batch worst offenders: security-scan.sh, build-push.sh, coverage-check.sh, scaffold-api.sh → first-comment contract, --help+EXAMPLES, semantic exit codes, stream separation. Behavior-preserving. | Codex | GLM: before/after output diff on happy path must be stdout-identical (data), only stderr/help may change |
| R6 | Docs truth pass: AGENTS.md refresh (52 commits stale — counts, directory table, key-resources vs disk; mention fleetflow/parallel-ops), PLAN.md inventory + this plan linked, test-floor policy added to SKILL-CREATION-PROTOCOL.md ("new skill ships ≥1 smoke assertion"). | Sonnet | doc-drift gate + orchestrator read |

## Phase 4 — Deferred follow-ons (not this wave)

- skill-telemetry as auto-skill extension (extend track-tools.sh; PostToolUse on Skill tool) — build after the wave, feed quarterly culls.
- Marketplace submission (unblocked once T3 lands).
- Private claude-mods-local repo formalizing the ~/.claude-only overlay (user-driven).
- push-cadence SessionStart advisory — only if the pile-up recurs post-wave.
- NOT building: eval-ops, memory-gardener, release-train (verdicts above).

## Expected outcomes

| Metric | Before | After |
|---|---|---|
| Context tax | ~46k chars / 11.5k tok | ~31k chars / ~7.8k tok (−3.7k tokens **per session**) + CI-capped forever |
| repo-doctor CRITs | 2 | 0 (via gates, zero splits) |
| Skills with tests | 31 | 46 (all 13 HIGH covered) |
| Fleet-family routing | 5 SKILL.mds to read | 1 router, 3 collisions resolved |
| Marketplace-clean | no (4 coupled files) | yes |
| CI blind spots | 3 (count sites, frontmatter ghosts, description budget) | 0 |
| Unpushed commits | 101 | 0, CI green |

## fleetflow execution notes

- Orchestrator: this session (Fable). Workers: Codex (code-heavy: gates, security suites, protocol backfill), GLM (mechanical: trims, wrappers, sanitization), Sonnet (doctrine prose: router, AGENTS.md).
- Every lane in its own worktree (worker-escape lesson: check main is clean post-run).
- Cross-model adversarial verify per lane as tabled; fleet-ops sequential landing with `bash tests/validate.sh && bash tests/doc-drift.sh` as the gate; check-resources.sh where scripts changed.
- Phase gate: CI green on origin/main before Phase 1 lanes spawn.
