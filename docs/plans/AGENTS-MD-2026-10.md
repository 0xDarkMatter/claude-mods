# AGENTS.md create / audit / upgrade / survey (2026-10)

Build spec and decision record for making claude-mods the place to **create, audit and
upgrade** a repository's `AGENTS.md`, and to **survey a whole GitHub org** for them.

## Decision (SKILL-CREATION-PROTOCOL step 0): extend repo-doctor, no new skill

**Chosen:** everything AGENTS.md-specific lands in `skills/repo-doctor/`. `doc-scanner`
hands its "generate an AGENTS.md" step to repo-doctor's scaffold.

Why:

- repo-doctor already owns the entry-doc standard (`references/entry-docs.md`), the
  skeleton (`assets/AGENTS-template.md`) and the scorer's `entry_docs` dimension.
  doc-scanner already defers to that template. A new skill would be a second judge of
  the same file, and two judges drift.
- The tools are one family over one contract: the scan produces facts, the scaffold
  renders them, and the audit checks a doc against the same facts. Keeping them beside
  the protocol means the downstream port (a team plugin taking the protocol and
  templates) copies one folder with no `../../` paths.
- repo-doctor's stance is read-only. The only writing tool is the scaffold's `--write`,
  and it only ever **creates** an `AGENTS.md`. It refuses to overwrite one, with no
  `--force`, because overwriting is how an owner's landmines get lost.

Rejected:

| Alternative | Why not |
|---|---|
| New `agents-md-ops` skill | It duplicates repo-doctor's entry-doc scope and template, and needs a second, drifting copy of the rubric |
| Split across three skills (scaffold in doc-scanner, audit in repo-doctor, survey in github-ops) | The scaffold would need repo-doctor's templates through a cross-skill path, and the protocol would sit away from two of its three tools |
| Extend `github-ops`' `repo-scorecard.sh --org` | Its subject is GitHub hygiene (security, metadata, releases). The survey reuses its *pattern* (GET-only `gh api`, owner validation, exit 7 on unavailability), not its code |

## What ships

| Piece | Path (under `skills/repo-doctor/`) |
|---|---|
| Protocol: contents, exclusions, size and split, CLAUDE.md interplay, staleness | `references/agents-md-protocol.md` (supersedes `entry-docs.md`) |
| Deep scan: read-only, deterministic facts JSON, every fact sourced, plus git-history landmine candidates | `scripts/repo-scan.py` |
| Scaffold, audit/upgrade (`--diff`), org survey | `scripts/agents-md.py` |
| Archetype templates: PHP CMS + DDEV + bundler, Node/TS app, Python service, static site | `assets/agents-md/*.md` |
| Live tripwire for the encoded Claude Code facts | `scripts/check-memory-docs.py` (`--offline` in PR CI, `--live` in `freshness.yml`) |

## Evidence the design answers

A read-only survey of 64 web repositories in one organisation (2026-10-05):

- 48 had no `AGENTS.md` or `CLAUDE.md`, 14 had `AGENTS.md` only, 2 had `CLAUDE.md` only.
- The 14 existing files were fresh (6 commits since the last touch at most) and nearly
  all covered commands, tests, landmines and structure.
- 6 of the 14 ran past 200 lines (225 to 595), so the split proposal matters more than
  freshness.
- Typical stacks: a PHP CMS with DDEV and Laravel Mix or Vite, Node/TypeScript apps, a
  few Python services. About half deploy through an AWS CodeDeploy `appspec.yml`, so
  the scan follows the hooks into the scripts they call.

The gap is creation (48 of 64) and size, not staleness. The scaffold and the split
proposal are the high-value pieces. Landmine candidates mined from git history are the
part a human can't easily produce by hand.

## Status

Built on `lane/agents-md`. Landing, push and install are the coordinator's call.
