---
name: unknown-key
description: Fixture for tests/spec.sh - MUST FAIL. A misspelt Claude Code field is an unknown key.
when-to-use: Hyphenated typo of when_to_use. Claude Code would silently ignore it.
---

Fixture for `tests/spec.sh`. `when-to-use` is not a spec field and not a Claude Code
field (the real one is `when_to_use`), so the official validator must reject it. This is
the typo the allowlist exists to catch.
