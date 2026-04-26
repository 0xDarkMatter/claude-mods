# Release Strategy

Default version-bump policy for github-ops mode `update`.

| Change type | Bump | Example |
|---|---|---|
| New feature, capability, command, integration | **minor** (default) | 0.1.0 → 0.2.0 → 0.3.0 |
| Bug fix, small QoL tweak, doc-only fix, dep bump | **patch** | 0.2.0 → 0.2.1 → 0.2.2 |
| Breaking change / 1.0.0 promotion | **major** — REQUIRES EXPLICIT APPROVAL | never auto-suggest |

## Decision logic (apply in order)

```
1. Inspect commits since last tag:
   git log $(git describe --tags --abbrev=0)..HEAD --oneline

2. Categorise by Conventional Commits prefix:
   feat:     → feature signal
   fix:      → fix signal
   chore: docs: style: perf: test: refactor: → housekeeping signal
   BREAKING CHANGE: in body, or !: in subject → breaking signal

3. Decide bump:
   IF any breaking signal:
     STOP. Surface to user with the breaking commits listed.
     Ask explicitly: "These changes look breaking. Bump to v<next-major>.0.0,
     or treat as v<current-major>.<next-minor>.0 with breaking-change notes?"
     NEVER auto-major.

   ELSE IF any feature signal:
     bump = minor
     New version = bump <current>.<minor + 1>.0

   ELSE (only housekeeping/fix signals):
     bump = patch
     New version = <current>.<minor>.<patch + 1>
```

## README touch policy by bump

| Bump | README "Recent Updates" | README body sections |
|---|---|---|
| patch | **always** update (single-bullet block) | skip unless explicitly asked |
| minor | **always** update (multi-bullet block) | scan diff for new commands/config/install steps; touch only if found |
| major | **always** update (lead with breaking change) | always update (and major needs approval anyway) |

The "Recent Updates" section is the one README touch that always happens. Body changes for minor/major are conditional — checked against the diff, not assumed.

## Rationale

User-stated preferences for 0xDarkMatter repos (codified 2026-04-26):
- Most work is feature-shaped, so minor is the default — predictable cadence
- Patches reserved for genuine fixes — preserves signal of what a patch means
- Pre-1.0 stays pre-1.0 until explicitly promoted — no accidental "this is stable" signal
- Treat `BREAKING CHANGE:` markers as a signal to ask, not as authorization to bump major

## Mapping to standard semver-from-commits

Aligns with the conventional-commits semver mapping with one explicit override: major bump is gated behind user approval even when breaking-change markers are present in commits. Everything else matches the standard mapping.

## Edge cases

- **Empty range** (no commits since last tag): refuse to release; nothing to ship.
- **Mixed feat + fix**: minor (feat dominates).
- **Only chore/docs**: patch (treat as housekeeping release).
- **First release** (no prior tag): default to v0.1.0, ask for confirmation.
- **Tag exists for current HEAD already**: refuse (already released this commit).
