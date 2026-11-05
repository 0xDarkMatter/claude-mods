---
name: linear-ops-triggers-api
description: A script hitting Linear's GraphQL API with rate limits and bulk updates loads linear-ops
tags: [trigger, linear-ops]
runs: 3
max_turns: 4
timeout_seconds: 180
allowed_tools: [Skill, Read, Glob, Grep]
---

My Node script talks directly to the Linear GraphQL API with a personal API key. It needs to reprioritise about 300 issues, and it keeps getting RATELIMITED errors, plus a "query too complex" rejection on the read. There's no MCP in this environment. How should I structure the reads and the updates?
