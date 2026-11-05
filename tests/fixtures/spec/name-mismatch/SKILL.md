---
name: some-other-name
description: Fixture for tests/spec.sh - MUST FAIL. The name field does not match the directory.
---

Fixture for `tests/spec.sh`. The spec requires `name` to equal the parent directory
name; this file sits in `name-mismatch/` but declares `some-other-name`.
