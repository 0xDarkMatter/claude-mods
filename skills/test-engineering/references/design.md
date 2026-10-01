# Design mode: failure modes first

**Output:** a failure list where every row is a named test with a level, an oracle and its
doubles. Design never produces "happy path + edge cases"; it produces the bugs the tests
must catch.

## 0. Read (or propose) the profile

Read `.test-profile.yml` at the repo root (schema: [profile.md](profile.md)). If it is
missing, propose one and **ask before writing it**; never apply a proposal silently.

| To propose | Look at |
|---|---|
| `shape` | manifests and entry points: a `bin` field or console script (`cli`), an MCP SDK dependency (`mcp-server`), a Workers/HTTP framework (`http-service`), a UI framework (`web-ui`), media or ETL tooling (`*-pipeline`), an LLM SDK (`llm-feature`) |
| `zones` | paths and identifiers: billing/invoice/price/amount (`money`), auth/token/session/oauth (`auth`), email/phone/address/dob (`pii`), send/delete/charge/book/publish (`irreversible`) |
| reviewers | `greptile.json` or `.greptile/`, Greptile check runs or bot comments on recent PRs (see [ai-reviewers.md](ai-reviewers.md)) |

Then say what detection cannot see, and ask: writes routed through a registry or generic
client do not look irreversible to a keyword scan, and nothing can infer `mission-critical`.
A human names those.

## 1. List the failures before any test exists

1. **For every guard in the change, write its negative case (G1):** the forged, empty,
   expired, wrong-tenant or second-party input that the guard must refuse.
2. **Walk [gap-classes.md](gap-classes.md)** and keep every class that applies. Zone tags make
   some classes mandatory (money: G7/G3/G2; auth: G1/G12; pii: G12/G10; irreversible:
   G9/G4/G6).
3. **Ask what nobody warned about.** Sites that carry a warning comment are tested far more
   often than sites that do not; the unflagged behaviour is where survivors live. For each
   risky function ask "what failure here has no comment, no ADR and no landmine entry?"
4. **One behaviour per row.** If a row says "handles errors", split it until each row names
   one bug a mutant could plant.

## 2. Pick the level: the boundary users hit

HTTP response, CLI exit code and stdout, tool result, public API. Unit tests only for logic
with many cases (money, dates, parsing, permissions), table-driven. The level is where the
bug would be **observed**, not where it is easiest to call.

## 3. Pick the oracle

| Oracle | Use | Never |
|---|---|---|
| Hand-derived value, with the derivation in a comment | most tests | - |
| Spec or standard vector (RFC test vectors, a published example) | crypto, encodings, protocols | - |
| Independent implementation (a simpler, slower one) | arithmetic, parsers, property tests | - |
| Reviewed characterisation (a recorded output a human checked) | legacy pins before a refactor | as the only guard of a rule |
| The function under test, or a copy of it pasted into the test | - | ever (S3, S15) |

## 4. Pick the doubles

Real lightweight dependencies first: SQLite or D1 with the real migrations, temp dirs, an
in-process server, a spec-validating simulator. Mock only at **process boundaries you do not
own** (third-party HTTP, email/SMS, payment providers) and control nondeterminism (clock,
randomness, ids) by injection. Never mock the unit under test. Details:
[mocking-strategies.md](mocking-strategies.md).

## 5. Property and fuzz tests where they fit

For money arithmetic, parsers, encoders and anything with an inverse: state the invariant
(parts sum to the total, sign symmetry, `decode(encode(x)) == x`, sorting is idempotent) and
let a generator find the counterexample (fast-check, Hypothesis, Go's native fuzzing). Pin
every counterexample found as an ordinary named test.

## Output format

| # | Failure (the bug) | Test name | Level | Oracle | Doubles | Class |
|---|---|---|---|---|---|---|
| 1 | spending exactly the limit is refused | `allows spending exactly the limit` | HTTP | hand-derived | real DB | G2 |
| 2 | a password-reset link works a second time | `refuses a reset link that was already used` | HTTP | hand-derived | real DB, fake mailer | G1, G9 |

Write mode takes this table as its input; each row becomes one test and one mutant record.
