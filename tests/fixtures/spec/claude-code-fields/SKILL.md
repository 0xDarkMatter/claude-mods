---
name: claude-code-fields
description: Fixture for tests/spec.sh - MUST PASS. Spec fields plus Claude Code's own top-level fields.
when_to_use: Proves the gate allows Claude Code fields instead of rejecting them.
argument-hint: "[target] [--flag]"
effort: high
disable-model-invocation: true
paths:
  - "*.md"
license: MIT
allowed-tools: Read Grep
metadata:
  author: claude-mods
  related-skills: "skill-a, skill-b"
---

Fixture for `tests/spec.sh`. It must pass: every top-level key is either an Agent
Skills spec field or a documented Claude Code field, and every `metadata` value is a
string. If the gate starts rejecting this file, the Claude Code allowance broke.
