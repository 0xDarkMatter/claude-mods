# Write mode: tests that are seen failing

**Output:** tests named for bugs, each **proved** (seen failing for the right reason against
a planted mutant or the unfixed code), or explicitly marked `unverified`.

## Steps (test-after shown; postures below reorder them)

1. **Take the failure list** from design mode, or derive one ([design.md](design.md)). Refuse
   to generate "happy path + edge cases" without naming the bugs.
2. **Write 1-3 tests per failure**, named for the bug they prevent, extending an existing
   test file before creating one. Follow the repo's conventions and the language skill
   (table at the end).
3. **Prove each one fails** with `scripts/mutate.mjs --prove` (below).
4. **Record the evidence** (the harness's JSON row) in the PR or task body.

## Prove it fails

For each test, write ONE mutant row for the code it guards (shape:
`assets/mutant.example.json`) and run:

```bash
node <skill>/scripts/mutate.mjs --runner vitest --catalogue m.json \
  --prove "refuses a reset link that was already used" -- test/reset.test.ts
```

| Result | Exit | Meaning | Do |
|---|---|---|---|
| `proved: true` | 0 | the named test went red on the mutant | keep it; paste the row as evidence |
| `killed-by-other` | 10 | other tests caught the mutant, the new one stayed green | the new test is weak or redundant for this behaviour: strengthen it, or drop it with that evidence |
| `survived` | 10 | nothing caught it | strengthen once (tighter assertion, the exact value); if still green, mark the test `unverified` and keep the obligation open |
| `suite-error`, `compile-error`, `type-killed` | 10 | red for the wrong reason | rewrite the mutant in a valid form, then re-run |
| baseline red | 5 | the suite fails before any mutation | fix the suite first (or `--keep-env` a variable it needs) |

**Mutant rules** (they keep the proof honest):
- Plant it **in the guarded code**, from a realistic operator (table below), never free-form.
- Never flip a literal the test asserts verbatim; that proves the assertion, not the test.
- **Bug fixes:** the mutant is the reverse of the fix (`old` = the fixed lines, `new` = the
  buggy lines). Seeing the new test fail on the old code is the strongest proof there is.
- **One behaviour, one mutant.** A test that covers three behaviours needs three rows.
- The harness, not the agent, writes the evidence row. Never hand-edit or summarise it.

## Operators that found real gaps

| Operator | Example | Class |
|---|---|---|
| Boundary flip | `>` to `>=`, `<= n` to `< n`, `slice(0, n)` to `slice(0, n - 1)` | G2 |
| Drop a guard or one clause | `if (!ok) return deny()` removed; `a && b` to `a` | G1 |
| Accept a wider shape | exact match to `startsWith`; drop a regex `$` anchor; accept an array audience | G12 |
| Swap an error class or retry decision | `retryable: false` to `true` on an ambiguous 5xx | G6 |
| Change a constant | a dedup window, a rate, a limit, a timeout | G7, G9 |
| Unit or rounding change | `Math.round` to `Math.floor`; ms to s; `* 100` to `* 10` | G7 |
| Skip one output path | redaction applied to the log line but not the preview | G12, G10 |
| Return the default | `return parsed ?? DEFAULT` where `parsed` was `false` | G11 |
| Drop a key component | remove one field from an idempotency or cache key | G9 |
| Unescape a template output | Twig `{{ x }}` to `{{ x\|raw }}`; Blade `{{ $x }}` to `{!! $x !!}`; drop `\|e('js')` | G12 |
| Drop a template guard | remove a `@can` / `{% if currentUser.can(...) %}` wrapper, `@csrf` or `csrfInput()` | G1, G12 |
| Drop a route or policy guard (Laravel) | remove `->middleware('auth')`, a `can:` middleware, or `$this->authorize(...)` | G1 |
| Widen what is accepted (Laravel) | drop one validation rule (`'required\|integer\|min:1'` to `'required\|integer'`); `$guarded = []` | G12 |
| Drop a tenancy scope | remove a `->where('tenant_id', ...)` or a global scope | G1, G12 |

PHP mutants are syntax-checked with `php -l` before any test runs; one that does not parse is
a `compile-error`, never a kill. Twig has no such check, so keep template mutants parseable.

## Postures

The evidence standard is identical in every posture; only the order of work changes.
Gates check evidence, never order. The repo default is `posture:` in the profile; any run
can override it with `--posture`.

| Posture | Order | What counts as the red | The trap it guards |
|---|---|---|---|
| `test-after` | code, failure list, tests, **prove it fails** | the named test red on a planted mutant (or on the unfixed code) | tests that restate the code they were written after |
| `tdd` | failure list, one test, **red**, minimal code, green, refactor, next | an **assertion failure on a value**. A missing symbol, ImportError, or "not implemented" throw earns no credit; a minimal stub to reach the assertion is fine | red for the wrong reason; a first test satisfied by an over-general implementation |
| `characterise` | pin current behaviour before a refactor | each pin fails under a mutant of the behaviour it pins | pins of incidental output that will be "fixed" by re-recording (S4) |

In `tdd`, still run `--prove` once the code exists: the red you saw was against missing
code, and the planted mutant is what shows the test pins the finished behaviour. When it
does not, it has found the over-general implementation. [tdd-workflow.md](tdd-workflow.md)
has the cycle in detail.

## How much proof (strictness)

| `standard` | `strict` | `critical` |
|---|---|---|
| bug-fix tests must be proved | every new test must be proved | every new test proved, and the evidence row is in the PR body |

Inside a zone, the zone's level applies ([profile.md](profile.md)).

## Language routing

Read the language skill for idioms before writing, and follow the repo's existing test
layout. Framework examples: [frameworks.md](frameworks.md).

| Files | Read | Runner for `--prove` |
|---|---|---|
| `*.ts`, `*.js`, `*.mjs` | typescript-ops / javascript-ops | `vitest` or `jest` |
| `*.tsx`, `*.jsx`, `*.vue` | react-ops / vue-ops | `vitest` or `jest` |
| `*.py` | python-pytest-ops | `pytest` |
| `*.go` | go-ops | `go` |
| `*.php`, `*.blade.php` (Laravel) | laravel-ops | `pest` or `phpunit` |
| `*.twig` (Craft, Symfony) | craftcms-ops | `phpunit` or `pest` through a render test; `command` for Codeception |
| `*.rs`, `*.sh`, anything else | rust-ops / bash-ops | `command` (run only the test being proved) |
| browser e2e and component tests | playwright-ops / cypress-ops | `command`, and see the visual and e2e policy in profile.md |

## Evidence in the PR body

```
Seen failing:
- refuses a reset link that was already used
  mutant AUTH-1 (src/auth/reset.ts, drop the used-token clause): proved, exit 0
- spending exactly the limit is allowed
  mutant LIM-1 (src/limit.ts, > to >=): proved, exit 0
Unverified: none
```
