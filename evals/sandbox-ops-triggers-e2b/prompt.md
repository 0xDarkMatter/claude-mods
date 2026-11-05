---
name: sandbox-ops-triggers-e2b
description: Spinning up an E2B sandbox for a two-hour agent job loads sandbox-ops
tags: [trigger, sandbox-ops]
runs: 3
max_turns: 4
timeout_seconds: 180
allowed_tools: [Skill, Read, Glob, Grep]
---

I want to spin up an E2B sandbox and let a coding agent work in it for about two hours on a refactor, then pull the diff back. What do I need to set so the sandbox doesn't die halfway, and how do I make sure nothing is left running or paused afterwards?
