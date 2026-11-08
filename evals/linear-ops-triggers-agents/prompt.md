---
name: linear-ops-triggers-agents
description: Setting how coding agents should behave in a shared Linear workspace loads linear-ops
tags: [trigger, linear-ops]
runs: 3
max_turns: 4
timeout_seconds: 180
allowed_tools: [Skill, Read, Glob, Grep]
---

Several people's coding agents now file and update issues in our Linear workspace, and it's getting messy: duplicates, fields overwritten, and nobody can tell which comments a person actually wrote. What rules should our agents follow when they create, claim, hand off and close issues?
