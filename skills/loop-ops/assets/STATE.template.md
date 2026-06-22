# <loop-name> — STATE
_Updated: <ISO-8601 Z> · run #0 · readiness 100/100_

<!--
The triage snapshot. The loop READS this at the top of every run and REWRITES it at
the end. Not a database — a lightweight snapshot of: what to act on, what to watch,
what was seen-and-dismissed. Read/write contract: references/state-spine.md.
First action of every run: check the kill switch, then read the Priority list.
-->

## Priority   (act on these next)
<!-- the next units of work, highest first. e.g. "[P1] PR #412 failing CI 3h" -->
- (none yet)

## Watch      (not yet actionable)
<!-- things being tracked that aren't ready to action -->
- (none yet)

## Noise      (seen + dismissed this run)
<!-- items deliberately skipped, so the next run doesn't re-surface them -->
- (none yet)

---
_Source: <scheduler, e.g. .github/workflows/<loop-name>.yml> · config: loop.config.yaml_
