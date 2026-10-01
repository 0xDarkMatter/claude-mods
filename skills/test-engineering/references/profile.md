# The profile: one doctrine, tuned per repo

`.test-profile.yml` at the repo root, linked from the `## Testing` section of AGENTS.md. Every
mode reads it. With no file, the defaults apply (`standard`, `test-after`, no zones) and design
mode proposes one, then asks before writing it.

**What no setting changes:** a test is seen failing for the right reason, named for the bug,
checked against an independent oracle, at the boundary users hit. Settings change only *how
much evidence* is demanded, *which kinds of test* are in play, and *the order of work*.

## Schema

```yaml
version: 1
shape: [http-service, cli]      # cli | mcp-server | http-service | web-ui | data-pipeline |
                                # media-pipeline | llm-feature | library  (one or more)
strictness: standard            # standard | strict | critical
posture: test-after             # tdd | test-after  (repo default; a run may override)
kinds: {}                       # exceptions to the shape defaults, e.g. { e2e: full, visual: review }
zones:                          # path globs -> risk tags; level defaults from the tags
  - { paths: ["src/billing/**"], tags: [money] }
  - { paths: ["src/payroll/**"], tags: [mission-critical] }
  - { paths: ["src/cli/**"], tags: [], level: standard }   # explicit level overrides the default
```

Annotated copy: [`assets/test-profile.example.yml`](../assets/test-profile.example.yml).
Monorepos may scope a zone with `package: packages/api`.

## Strictness

A file's level is its zone's level if it is in a zone, else the repo's `strictness`. Zones
tagged `money`, `auth`, `pii` or `irreversible` default to `strict`; `mission-critical` is
always `critical`. One repo can be relaxed in its CLI glue and uncompromising in its invoicing.

| | standard (default) | strict | critical |
|---|---|---|---|
| Prove-it-fails for new tests (write mode) | bug-fix tests | every new test | every new test, evidence row in the PR body |
| Audit mutants per zone file | 2 | 4 | 6 |
| Independent oracle required | money zones | every zone | everywhere |
| Visual baseline updates | the diff image in the PR | the diff image in the PR | approved by a named human |
| Blind reviewer's security lens | inside `auth` and `pii` zones | inside `auth` and `pii` zones | the whole repo |
| CI gate (v1) | exact checks block (gate.md) | same | same |

## Zone tags

| Tag | Failure classes design must list | Technique and oracle |
|---|---|---|
| `money` | G7 units, rounding, sign; G3 totals, ties, ordering; G2 period and bucket edges | hand-derived vectors or spec examples; property tests where they fit (parts sum to the total, sign symmetry) |
| `pii` | G12 redaction on **every** output path (logs, stdout, errors, previews, exports); G10 | a canary that provably enters the input, then a deep walk over the whole payload |
| `auth` | G1 a negative case per guard (forged, empty, expired, second party); G12 exact match, anchors, audiences | real crypto in tests (signed test tokens), never a mocked verifier |
| `irreversible` (external writes, money movement, deletes, sends) | G9 idempotency and retry; G4 partial failure; G6 ambiguous outcomes; the confirmation gate's negative path | a wire-recording fake that asserts what did NOT go out |
| `mission-critical` | every class that applies, plus G11 "off" spellings | two reviewer lenses; never inferred, only declared |

## Shape defaults (kinds)

The profile's `kinds:` lists only exceptions; an explicit kind beats the shape default.

| Shape | Default kinds |
|---|---|
| `cli` | integration through the real entry point (subprocess or CliRunner): exit codes, stdout as data, stderr as human text |
| `mcp-server` | wire tests through the real server; stdout hygiene (G10); tool descriptions under a drift gate (G13) |
| `http-service` | integration in the real runtime with real migrations; contract tests against a simulator |
| `web-ui` | component tests (Testing Library, Vue Test Utils); for server-rendered templates (Twig, Blade), an escaping test on every output of user data; e2e smoke on critical journeys; `visual: drift`; a11y when public |
| `data-pipeline`, `media-pipeline` | golden artefacts built at test time with tolerances, not byte snapshots |
| `llm-feature` | deterministic parts as normal tests; output quality handed to evals-ops |
| `library` | table-driven unit tests; property tests for parsers and arithmetic |

## Visual, e2e and browser drivers

Driver choice is not this skill's decision: use what the repo already runs, and the mechanics
in playwright-ops or cypress-ops. This skill decides whether and how strictly.

- **Component tests carry the breadth, e2e the journeys.** `e2e: smoke` is one test per critical
  journey through the built artefact, asserting an outcome and keeping an artefact (screenshot,
  trace); `e2e: full` is journeys x roles. E2e is never the only guard of a rule: it fails one
  layer too far from the cause.
- **Retries are flake telemetry.** "Passed on retry" is flaky, not green (triage.md).
- **Network stubbing** (`page.route`, `cy.intercept`) is fine at the API edge, and slop when it
  stubs the very response logic under test (S9).
- **Visual regression is a change detector (S4):** it catches unintended UI change and proves no
  behaviour, and its red is "fixed" by accepting a new baseline. `visual: drift` runs it and
  requires a reviewed baseline update; `visual: review` also attaches before, after and diff
  images to the PR. An agent never runs `--update-snapshots` without the diff image in the PR;
  at `critical`, a named human approves it.
- Visual and e2e suites are too slow for per-mutant audit runs; they take part in bug-fix proofs.

## Posture

`tdd` and `test-after` are developer preferences, not policy: the repo default lives here, any
run may override it, and no gate checks the order of work, only the evidence. Write mode has
the procedures ([write.md](write.md)).

## Security: protect the guards here, find the holes elsewhere

| Question | Owner |
|---|---|
| Is there a hole? (missing or wrong logic) | security-ops, and for a full discovery audit its optional pinned companion |
| Would we notice if a guard broke? | this skill: `auth` and `pii` zones, G1 and G12, a proved test per guard |

No mutation of existing code can reveal logic that was never written, and a discovery audit
sees a guard is present and moves on. A confirmed security finding comes back here as a
regression test, seen failing against the vulnerable revision; a survivor at a guard goes the
other way, to security triage (is it reachable?).
