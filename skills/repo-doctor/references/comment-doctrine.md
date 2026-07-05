# Comment Doctrine — inline documentation that survives the session

The doctrine in one sentence: **comments carry what the code cannot — constraints,
invariants, reasons, and formats — written at the site where a future agent would
otherwise guess.** Everything else is noise the next reader pays for.

Derived from a 2026-07 audit of 10 production repos: the practices below are the ones
that measurably separated the agent-navigable repos (4.5+/5) from the grep-and-pray
ones. Each pattern cites the real failure it prevents.

---

## 1. The contract block (top of every substantive file)

3–12 lines answering: what is this module, what invariants does it enforce or rely on,
where does the reasoning live.

```python
"""Event-to-ORM projection dispatch.

Two invariants guide the design:
* Idempotency. Re-applying the same JSONL line must leave the ORM identical.
* Best-effort side-effects. A payload missing a field skips its side-effect,
  never raises — the journal row is still written.
See docs/adr/ADR-007-journal-projection.md for why events, not state sync.
"""
```

```typescript
// Push orchestration: validate selection -> reserve (durable intent + locked
// records) -> create ACCREC DRAFT in Xero -> finalise. Crash-safe + idempotent.
// Token store: tenant's xero connector (AES-GCM at rest). See ADR-006/010.
```

The strongest form states a **law**: `// THE ONLY MODULE THAT TOUCHES D1 — enforced by
scripts/check-no-raw-d1.mjs` or `// Determinism: no Math.random, no transcendentals,
no Date.now — replay must be byte-identical`. A law + the gate that enforces it is what
makes even a 9,000-line file safe to work in.

For CLI scripts, the contract block IS the interface contract — Usage / Input / Output /
Stderr / Exit codes / Examples (see docs/SKILL-RESOURCE-PROTOCOL.md for the full form).

## 2. WHY-only inline comments

A comment must add information the code can't express. Test: delete the comment — if a
competent reader loses nothing, it was noise.

| Earns its place | Noise |
|---|---|
| `// order-independent so the same edited set retries to the same key` | `// build the key` |
| `# 0.0 means "no prior evidence", NOT "known failure" — scheduler treats them differently` | `# set default to 0.0` |
| `// curves wide of the headland; previous loop ran overland and beached a yacht in a farm dam` | `// ferry route points` |
| `// budget shared across all skills: 1% of context; overflow silently drops descriptions` | `// check the budget` |

State: units, ranges, encodings, ordering guarantees, failure behaviour, and the
*reason* a value is what it is. Never narrate control flow.

## 3. Guard comments — protecting deliberate weirdness

**The agent-specific failure mode.** An agent that can't see why the code has its
strange shape will "improve" it. Real regressions this pattern prevents (all observed):

- A 1,300-line single-file HTML app split into ES modules → **`file://` preview broke**
  (modules need HTTP). The single file was the feature.
- A reused sort buffer inlined "for clarity" → per-frame allocation, **GC churn back**.
- An unexplained idempotency-key format "tidied" → **retries stopped deduplicating**.

The pattern — lead with `ARCHITECTURE:`/`PERF:`/`FORMAT:`, state the constraint, name
what breaks:

```javascript
/* ARCHITECTURE: classic script, ONE file — not modules, no bundler.
   file:// preview must work; ES modules fail on file:// (CORS).
   Splitting this file breaks "open index.html" and the zero-dep contract. */
```

```javascript
// PERF: _sortBuf is reused across frames — do NOT inline or reallocate;
// per-frame allocation regresses GC pauses on 500+ sprite scenes.
```

```typescript
// FORMAT: `${tenantId}|receivable|${clientId}|${sortedRecordIds}|${contentHash}`
// recordIds sorted so retries of the same set hash identically; contentHash so
// a manual-only push can't collide with a different manual set. ADR-010.
```

Anything that would fail a naive code review for a *reason* needs one of these. Cost:
2–5 lines. The alternative: a future session confidently reintroducing a solved bug.

## 4. Section markers and file maps

- **>400 lines** → `// === SECTION ===` markers between logical regions.
- **>800 lines** → also a top-of-file map so an agent jumps instead of scrolling:

```javascript
/* Sections: STATE · MATH · RENDER · COMMANDS(+history) · INPUT · IO · BOOT
   All scene mutations funnel through dispatch(type, payload) — extend COMMANDS
   + makeInverse together when adding mutation types. */
```

Note what that example does beyond navigation: it states the **extension contract**
(COMMANDS + makeInverse move together) exactly where an agent adding a feature lands.

## 5. Formats at the construction site

Wire formats, cache keys, hash inputs, file-name grammars, magic strings: document the
grammar **where the string is built**, even when an ADR also covers it. An agent editing
the construction line will not have the ADR in context; the comment is the last line of
defense. One line of grammar + one line of why per component is enough.

## 6. Citations — making domain code modifiable by non-domain agents

Embedded domain knowledge gets its source cited inline: standards (`AS 1743 guide-sign
green`), papers (`Potrace 2003 §2.2 — penalty-DP optimal polygon`), external IDs (`OSM
way 6261378 — the real ferry route`), RFCs, spec sections. A citation converts "magic
constants an agent must not touch" into "parameters an agent can verify and adjust."

## 7. Docstrings / JSDoc

Public API gets a docstring when the signature under-specifies: side effects, error
behaviour, units, ordering/nullability guarantees, "who calls this and when". Private
helpers with honest names need nothing. Never write ceremony docstrings that restate
the name — they train readers to skip all docstrings.

## 8. What NOT to write

- WHAT-narration (`// increment the counter`)
- Reviewer-directed remarks (`// fixed per feedback`) — that's PR conversation, not code
- Commented-out code — git remembers; delete it
- Bare `TODO` — either `TODO(owner/context): action — see #issue` or nothing
- Changelog-in-comments (`// 2026-07: changed X`) — git owns history

## Retrofit order (existing repo)

1. Guard comments on everything deliberately weird — highest value per line, prevents
   active regressions.
2. Contract blocks on the 10 largest / most-touched files.
3. Section markers + maps in >400/>800-line files.
4. Format comments at key/hash/wire construction sites.
5. Citations in domain-heavy modules.

Run `scripts/repo-doctor.py` before and after — `comments` dimension should move first.
