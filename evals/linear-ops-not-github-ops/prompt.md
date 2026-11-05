---
name: linear-ops-not-github-ops
description: Triaging GitHub issues with gh has nothing to do with Linear and must not load linear-ops
tags: [near-miss, linear-ops]
runs: 3
max_turns: 4
timeout_seconds: 180
allowed_tools: [Skill, Read, Glob, Grep]
---

Our GitHub repo has about 40 open issues with no labels. I want to triage them from the terminal with `gh`: list them, add labels, close the stale ones, and comment on a few. What's a safe way to do it?
