<!-- Archetype: Python service. Rendered by scripts/agents-md.py scaffold from repo-scan
     facts; also usable by hand. Slots: {{TITLE}} {{DRAFT_NOTE}} {{OVERVIEW}} {{COMMANDS}}
     {{LANDMINES}} {{DEPLOY}} {{STRUCTURE}} {{CONVENTIONS}} {{POINTERS}} {{QUESTIONS}}.
     Everything outside the slots is the archetype's own prompts, written as
     TODO(owner) questions, never as claims. Protocol: references/agents-md-protocol.md -->
# Agent Instructions - {{TITLE}}

{{DRAFT_NOTE}}

{{OVERVIEW}}

## Commands

{{COMMANDS}}

## Landmines

<!-- Mandatory. Turn each confirmed TODO(owner) into a numbered landmine: what breaks,
     why, and the procedure. Delete the ones that are not rules. -->

{{LANDMINES}}
- [ ] TODO(owner): How are database migrations created and applied, and may an agent generate one?
- [ ] TODO(owner): Which settings or environment variables does the service refuse to start without?

## Deploy

{{DEPLOY}}

## Structure

{{STRUCTURE}}

## Conventions

{{CONVENTIONS}}

{{POINTERS}}

{{QUESTIONS}}
