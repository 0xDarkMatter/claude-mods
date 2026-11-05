## Testing

- Policy: `.test-profile.yml` (strictness, posture, risk zones); budget: `.test-budget.json`.
  Work with the test-engineering skill: design, write, audit, prune, speed, gate, triage.
- Every new test is **seen failing for the right reason** (an assertion on a value, against a
  planted mutant or the unfixed code) and is named for the bug it prevents. Put the evidence
  row in the PR body; a test that cannot be proved is marked `unverified`, never silently kept.
- **A test earns its CI seconds.** 1-3 tests per behaviour change; extend an existing test
  file before creating one. A new test over `<max_test_s>` s goes to a slower tier or gets a
  faster fixture: the budget gate blocks it otherwise. No sleeps, real clocks or real network
  in unit tests.
- **Run only what the change needs, somewhere else.** Inner loop: `<changed-only command>`.
  Full runs go to `<offload target: CI / a named machine>`, not this workstation; local runs
  are parallel and capped (`run-plan.py local`).
- Deleting a test that catches nothing its neighbours do not is an improvement: one module
  per PR, with the evidence table (test-engineering prune mode).
- No coverage targets. Mock only at process boundaries; never the unit under test.
- Test-related review threads (human or AI reviewer) are resolved with prove-it-fails
  evidence (test-engineering triage), never by resolving a false positive silently or adding
  a test that cannot fail.
- Run tests: `<the repo's test command>`. CI blocks on: `<lost tests, failOnRisky, the budget>`.
