---
name: flow-style
description: Fixture for tests/spec.sh - MUST FAIL. Inline flow-style YAML in the frontmatter.
paths: ["*.ts", "*.tsx"]
---

Fixture for `tests/spec.sh`. Claude Code accepts `paths: ["*.ts"]`, but skills-ref
parses frontmatter with strictyaml, which rejects flow style (`[a, b]`, `{k: v}`).
Write lists in block style (`- item` on its own line) instead.
