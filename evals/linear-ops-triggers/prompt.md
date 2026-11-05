---
name: linear-ops-triggers
description: Filtering Linear issues and getting a suspicious empty list loads linear-ops
tags: [trigger, linear-ops]
runs: 3
max_turns: 4
timeout_seconds: 180
allowed_tools: [Skill, Read, Glob, Grep]
---

I'm using the Linear MCP server from my agent. `list_issues` with team set to our platform team and state "In Review" came back empty, so it told me there's no work waiting. I don't believe that. How do I check, and how should I list issues without burning so much context?
