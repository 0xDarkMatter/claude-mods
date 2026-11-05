<!--
  test-engineering doctrine for an AI reviewer (opt-in, per repo; references/ai-reviewers.md).
  Copy into the repo's Greptile rules: a .greptile/rules.md scoped to the test directories, or
  rules[] entries in the Greptile config. Generated from slop-patterns.md (S1-S18) and
  gap-classes.md (G1-G13); edit those, then re-copy. Never add audit findings here.
-->
# Test review rules

When reviewing test files, comment only on these. For each, ask the question and name the test.

1. **Vacuous safety test.** A test named for a guarantee ("never leaks", "is redacted", "refuses
   X"): can the forbidden value actually reach what the test inspects? If not, the test cannot
   fail when the guarantee breaks.
2. **Assertions that may never run.** Assertions inside a loop over a possibly empty collection,
   after an early `return`, or inside an `if`. Ask for a non-empty check or a visible skip.
3. **Self-derived expectations.** The expected value is computed by the code under test, or the
   test re-declares a production function, handler or constant and tests the copy.
4. **Snapshot as the only guard of a rule.** A snapshot or byte-compare is the only thing that
   would catch a logic change; its red would be fixed by re-recording.
5. **Weak assertions where the value is known.** `toBeDefined`, truthiness, bare `toThrow()`,
   "exit code is not 0" when the exact value, error class or message is known.
6. **Mocking the unit under test**, or asserting only that a mock was called when an outcome is
   observable.
7. **Missing negative case for a guard** changed in this diff: forged, empty, expired,
   wrong-tenant or second-party input.
8. **Boundary not pinned** for a limit, threshold or bucket changed in this diff (equal to the
   limit, the first value past it).

Do not ask for tests merely to raise coverage. When asking for a test, describe the bug it
must catch. A requested test is only accepted with evidence it fails when that bug is present.
