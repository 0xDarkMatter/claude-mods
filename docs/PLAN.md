# Project Plan: claude-mods

**Goal**: A centralized repository of custom Claude Code commands, agents, and skills that enhance Claude Code's native capabilities with persistent session state, specialized expert agents, and streamlined workflows.

**Created**: 2025-11-27
**Last Updated**: 2025-11-27
**Status**: In Progress

## Context

Claude Code is powerful but has gaps:
- TodoWrite state doesn't persist between sessions (by design)
- Plan Mode thinking is lost when sessions end
- No built-in specialized expert agents for specific tech stacks
- No easy way to share custom configurations across machines

This project bridges those gaps with git-trackable, shareable extensions.

## Approach

Build modular, composable tools that:
1. Integrate seamlessly with native Claude Code features
2. Persist important state to git-trackable files
3. Provide specialized expertise via custom agents
4. Work across machines via git sync

## Implementation Steps

### Completed
- [x] Session continuity commands (`/plan --save`, `/plan --load`)
  - Completed: 2025-11-27
  - Persists TodoWrite state to `.claude/session-cache.json`
  - Human-readable progress in `.claude/claude-progress.md`

- [x] Plan persistence command (`/plan`)
  - Completed: 2025-11-27
  - Captures Plan Mode state to `docs/PLAN.md`
  - Auto-captures internal state on every invocation

- [x] Development workflow commands
  - `/review` - Code review with configurable depth
  - `/test` - Test generation with framework detection
  - `/explain` - Deep code explanation

- [x] Agent genesis system (`/agent-genesis`)
  - Completed: 2025-11-27
  - Generates expert agent prompts from templates

- [x] Expert agents collection
  - TypeScript, React, Vue, Cypress
  - Python, JavaScript, SQL, Postgres
  - Laravel, Payload CMS, Astro
  - AWS Fargate, Cloudflare Workers
  - And more...

- [x] Installation scripts
  - `install.sh` for Unix/macOS
  - `install.ps1` for Windows

### In Progress
- [ ] Documentation and examples
  - Started: 2025-11-27
  - Need usage examples for each command
  - Need agent selection guide

### Pending
- [ ] More expert agents
  - Next.js expert
  - Docker/Kubernetes expert
  - GraphQL expert
  - Testing frameworks (Jest, Vitest, Playwright)

- [ ] Enhanced `/plan` features
  - Automatic progress tracking from git commits
  - Integration with GitHub Issues
  - Milestone tracking

- [ ] Skill expansions
  - Code statistics skill
  - Dependency analysis skill
  - Security audit skill

- [ ] Cross-project sync
  - Settings sync across machines
  - Team sharing capabilities

## Open Questions

- [ ] Should agents auto-update from a central registry?
- [ ] How to handle agent versioning?
- [ ] Should there be a "recommended agents" list per project type?

## Success Criteria

- [ ] All commands documented with examples
- [ ] Installation tested on Windows, macOS, Linux
- [ ] At least 20 expert agents covering major tech stacks
- [ ] Session continuity works reliably across sessions
- [ ] Community contributions via PRs

## Notes

- Based on patterns from Anthropic's "Building Effective Agents" article
- TodoWrite non-persistence is intentional (confirmed via claude-code-guide)
- Plan Mode also doesn't persist (this project fixes that)

---
*Plan managed by `/plan` command. Last captured: 2025-11-27*
