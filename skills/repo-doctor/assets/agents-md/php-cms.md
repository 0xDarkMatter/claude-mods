<!-- Archetype: PHP CMS + DDEV + bundler. Rendered by scripts/agents-md.py scaffold from
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
- [ ] TODO(owner): Which CMS settings live in synced config files (e.g. project config) versus the database, and must an agent change them through the admin UI or the files?
- [ ] TODO(owner): Which local operations are destructive (database import, snapshot restore, clearing caches or asset indexes), and when may an agent run them?

## Deploy

{{DEPLOY}}

## Structure

{{STRUCTURE}}

## Conventions

{{CONVENTIONS}}

{{POINTERS}}

{{QUESTIONS}}
