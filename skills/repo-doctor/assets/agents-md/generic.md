<!-- Archetype: generic (tooling, scripts, libraries, infrastructure: anything without a
     web-app or static-site manifest). Rendered by scripts/agents-md.py scaffold from
     repo-scan facts; also usable by hand. Slots: {{TITLE}} {{DRAFT_NOTE}} {{OVERVIEW}}
     {{COMMANDS}} {{LANDMINES}} {{DEPLOY}} {{STRUCTURE}} {{CONVENTIONS}} {{POINTERS}}
     {{QUESTIONS}}. Everything outside the slots is the archetype's own prompts, written
     as TODO(owner) questions, never as claims. Protocol: references/agents-md-protocol.md -->
# Agent Instructions - {{TITLE}}

{{DRAFT_NOTE}}

{{OVERVIEW}}

## Commands

{{COMMANDS}}

## Landmines

<!-- Mandatory. Turn each confirmed TODO(owner) into a numbered landmine: what breaks,
     why, and the procedure. Delete the ones that are not rules. -->

{{LANDMINES}}
- [ ] TODO(owner): Which files are generated, copied or installed from elsewhere, so that a hand edit is lost or never reaches users?
- [ ] TODO(owner): Which files must change together (a registry, a manifest, mirrored scripts for two shells)?

## Deploy

{{DEPLOY}}

## Structure

{{STRUCTURE}}

## Conventions

{{CONVENTIONS}}

{{POINTERS}}

{{QUESTIONS}}
