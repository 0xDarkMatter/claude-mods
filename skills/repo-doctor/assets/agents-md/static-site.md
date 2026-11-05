<!-- Archetype: static site. Rendered by scripts/agents-md.py scaffold from repo-scan
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
- [ ] TODO(owner): Which directory is published, and is it built or edited by hand?
- [ ] TODO(owner): Are any pages generated from data files or templates, so that editing the output directly gets overwritten?

## Deploy

{{DEPLOY}}

## Structure

{{STRUCTURE}}

## Conventions

{{CONVENTIONS}}

{{POINTERS}}

{{QUESTIONS}}
