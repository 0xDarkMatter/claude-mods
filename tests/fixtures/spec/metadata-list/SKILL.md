---
name: metadata-list
description: Fixture for tests/spec.sh - MUST FAIL. A metadata value is a list, not a string.
metadata:
  author: claude-mods
  related-skills:
    - skill-a
    - skill-b
---

Fixture for `tests/spec.sh`. The spec makes `metadata` a map of strings to strings.
skills-ref 0.1.1 stringifies this list to "['skill-a', 'skill-b']" and passes it, so
spec-check.py's metadata supplement is what must catch it.
