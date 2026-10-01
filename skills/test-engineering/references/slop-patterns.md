# Slop patterns (S1-S18)

Tests that look like protection and are not. Every entry carries **one question**: answer it
for the test in front of you. Static heuristics flag candidates (and are mostly wrong: about
13% precise in a 13-repo survey), so a flag is a question for a reader, never a verdict.
Only S17 is mechanical enough to block a build.

Examples are anonymised composites of real findings: no audited repo's code, test names,
paths or bug text belongs here (see the note in gap-classes.md).

| Id | Pattern | The one question | Fix |
|---|---|---|---|
| S1 | **Vacuous safety test** - named for a guarantee ("never leaks", "is scrubbed", "refuses X") but the forbidden value can never reach what it inspects | If the guarantee broke, could this test fail? | Make the forbidden value provably enter the input (a canary), then assert on the whole output |
| S2 | **Assertion-free on some path** - asserts inside a loop over a maybe-empty collection, after an early `return`, or inside an `if` | Can this test pass with zero assertions executed? | Assert non-empty first; replace skip-by-return with a visible `skipIf` |
| S3 | **Mirror oracle** - the expected value comes from the code under test, or two outputs of the same code are compared | Where did the expected value come from? | Hand-derived values, a spec vector, or an independent implementation |
| S4 | **Change detector posing as a behaviour test** - a snapshot or byte-compare that "catches" logic bugs only because output changed; its red is fixed by regenerating, which ships the bug | Would a reviewer re-record this snapshot without reading it? | Assert the behaviour directly; keep the snapshot as drift detection only |
| S5 | **Copied magic values** - literals pasted from output with no independent reason they are right | Why is this number correct? | Derive it in a comment or from the spec |
| S6 | **Weak assertion where the value is knowable** - `toBeDefined`, truthiness, bare `toThrow()`, "exit code is not 0" | Do we know the exact value? Then why not assert it? | Assert the exact value, error class and message |
| S7 | **Source-text grep instead of behaviour** - regex over source, `inspect.getsource`, `fn.toString()` | Does this run the code, or read it? | Run the code; keep greps only as drift gates on a documented invariant |
| S8 | **One layer short** - the unit is tested but the bug lives in the wiring that calls it; the stub replaces exactly the code that matters | Is the stubbed layer where the bug would be? | Test through the caller (route, dispatcher, CLI entry point) |
| S9 | **Mock-the-SUT / interaction-only** - asserts a mock was called rather than what happened | What observable outcome does this pin? | Assert outcomes; a "no network call after a refusal" assertion is a real safety check, not slop |
| S10 | **Tests the infrastructure** - the subject is the simulator, fixture or harness | Does any shipped code run? | Point the test at product code, or move it next to the tool it tests |
| S11 | **Smoke-only** - "does not crash" under a name that claims more (columns, ordering, totals) | Does the name promise more than the assertion checks? | Assert what the name promises, or rename it |
| S12 | **Duplicate coverage** - re-pins what another test already pins | Would deleting it lose anything? | Delete it, with evidence that a neighbour kills the same mutants |
| S13 | **Swallowed failure** - assertions only in a `catch`, `.catch(() => null)`, `except: pass` | What happens if no exception is thrown? | Assert the throw explicitly (`rejects.toThrow(SpecificError)`, `pytest.raises`) |
| S14 | **Environment or order dependence** - needs a gitignored artefact, a real remote API, a lucky timing, or another test first | Does it pass in a clean checkout, alone, offline? | Build the artefact in the test; fake the network edge; control the clock |
| S15 | **Shadow implementation** - the test file re-declares a production function, handler or constant and tests the copy; it passes while shipped code is broken, and the copy drifts (worst case: a copy of the pre-fix code) | Does this test import the code it claims to test? | Import the real module; delete the copy |
| S16 | **Test of dead code** - the function under test has no caller in the product | Who calls this in production? | Delete the dead code and its test, or test the caller |
| S17 | **Lost test** - two Python test functions with the same name in one module or class; Python keeps the last, the first never runs and the count silently shrinks | (mechanical) | Rename. Gate it with ruff/pyflakes `F811` over `tests/` (see gate.md) |
| S18 | **Coverage filler** - written to satisfy a percentage: import checks, `isinstance` on a constant, a call with no assertion | What bug would make this fail? | Delete it; drop the coverage target that created it |

## Notes on the dangerous ones

**S1 is the costliest pattern** because it wears the label of protection. Typical shapes: a
"never exposes pricing" test inspecting a listing whose query never selects pricing columns;
an import-failure test whose fake intercepts a module path the code never imports; a
constant-time-compare test whose truth table passes with plain `===`; a redaction canary that
never enters the payload inspected. The check is always the same: trace whether the forbidden
value can reach what the test reads.

**S15 hides in plain sight** because the test passes and reads well. Look for a function,
route handler or constant declared inside a test file with the same name as one in `src/`
that the test does not import. The blind reviewer agent checks for it explicitly.

**S4 has a factory variant:** a project template that deletes snapshots and tells the user to
re-record them on day one, so every generated repo's oracle starts as its own output.
