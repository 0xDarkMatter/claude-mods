## Testing

- Policy: `.test-profile.yml` (strictness, posture, risk zones). Work with the
  test-engineering skill: design, write, audit, gate, triage.
- Every new test is **seen failing for the right reason** (an assertion on a value, against a
  planted mutant or the unfixed code) and is named for the bug it prevents. Put the evidence
  row in the PR body; a test that cannot be proved is marked `unverified`, never silently kept.
- No coverage targets. Mock only at process boundaries; never the unit under test.
- Test-related review threads (human or AI reviewer) are resolved with prove-it-fails
  evidence (test-engineering triage), never by resolving a false positive silently or adding
  a test that cannot fail.
- Run tests: `<the repo's test command>`. CI blocks on: `<the gate job, e.g. lost tests>`.
