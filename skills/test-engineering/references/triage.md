# Triage mode: one ruling per red test, survivor or review comment

**Output:** a ruling for each item (bug / test bug / flake / incomplete / equivalent / masked /
mutation-form problem) with the evidence that decided it. Never a ruling on prose alone.

## A test went red

1. **Reproduce on a clean base.** Same command, clean checkout, lockfile install.
2. **Check the count.** Did every test run? A red with a short count can be an environment
   problem (missing dependency, corrupt binary) rather than a test result.
3. **Re-run three times.** Red-green-red is a flake (below), not a pass.
4. **Read the failure, not the summary.** An assertion on a value points at behaviour; an
   import error, timeout or setup crash points at the environment or the test.
5. **Rule:** product bug (write the fix, keep the test) / test bug (fix the test, and prove the
   fixed test still fails on a planted mutant) / environment (fix the setup, note it).

Never `-u` a snapshot, re-record a golden file or regenerate a byte-compare to make red go
green without a behavioural explanation written down. That is how a visible bug ships (S4).

## A mutant survived

1. **Reachable?** Trace an input from a real entry point to the mutated line. Unreachable:
   record it, and consider deleting the dead code (S16).
2. **Equivalent?** Probe the input space (boundaries, types, empty values) before claiming the
   mutant cannot change behaviour. Most "equivalent" claims fail this step.
3. **Masked?** Another layer blocks it (a format check behind a schema validator that already refuses the input). Still a gap,
   lower consequence; record it with the masking layer named.
4. **Otherwise it is a real gap:** hand it to write mode as a failure row, with the survivor
   itself as the mutant to prove against.

## `type-killed` or `compile-error`

Not a catch. Rewrite the mutant in a type-valid, compile-valid form (keep the variable used,
keep the signature) and re-run before believing anything.

## Flaky tests

- "Passed on retry" is **flaky**, never green. Browser drivers and CI actions both retry by
  default; read their retry counts.
- A guard whose only test is flaky is treated as **unguarded**.
- Fix order: remove real nondeterminism (clock, randomness, ordering, shared state, network)
  before adding waits. Quarantine only with an owner and a date.

## An AI reviewer comment about tests

Greptile, CodeRabbit, Copilot review or a custom bot says "X is untested", "missing negative
case", "this test cannot fail" or "add a test for X". Treat the comment as a **predicted
gap**, exactly like a blind-reviewer prediction:

1. Derive the mutant the comment implies (the operator table in write.md).
2. Run it: `mutate.mjs --catalogue m.json --prove "<the test the comment is about>"`, or a
   one-row batch to see whether anything catches it.
3. **Killed:** reply on the thread naming the test and the evidence row, then resolve.
4. **Survived:** write mode adds the killing test, proved; reply with the evidence; resolve.
5. Never resolve a test-related thread on prose, and never add a test that cannot go red just
   to satisfy a reviewer score. Details: [ai-reviewers.md](ai-reviewers.md).
