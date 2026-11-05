<!-- ARCHITECTURE.md in matklad's shape (rust-analyzer's is the model): a bird's-eye
     view, entry points, a codemap that NAMES files, modules and types rather than linking
     them (links rot; readers use symbol search), invariants as labelled callouts (often
     absences), boundaries and cross-cutting concerns. Short, only what rarely changes,
     revisited a few times a year rather than kept in sync. Rendered by
     scripts/agents-md.py scaffold --architecture from repo-scan facts; also usable by
     hand. Slots: {{TITLE}} {{DRAFT_NOTE}} {{ENTRY_POINTS}} {{CODEMAP}} {{BOUNDARIES}}
     {{INVARIANTS}} {{FINGERPRINT}}. Protocol: references/agents-md-protocol.md -->
# Architecture - {{TITLE}}

{{DRAFT_NOTE}}

## Bird's-eye view

- [ ] TODO(owner): What problem does this repo solve, what goes in and what comes out? Three to five sentences.

## Entry points

{{ENTRY_POINTS}}

## Codemap

<!-- Where does X happen? Name the important files, modules and types; never link them. -->

{{CODEMAP}}

## Boundaries

{{BOUNDARIES}}

## Invariants

<!-- One callout per invariant, often an absence: "Architecture Invariant: the engine
     never imports the UI." Name the gate that enforces it, or say there is none. -->

{{INVARIANTS}}

## Cross-cutting concerns

- [ ] TODO(owner): Errors, logging, configuration, testing: where does each live, and what is the one way to do it here?

## What this is not

- [ ] TODO(owner): Which non-goals might a newcomer assume? (Tauri's non-goals section is the model.)

{{FINGERPRINT}}
