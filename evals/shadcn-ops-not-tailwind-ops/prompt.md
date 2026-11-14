---
name: shadcn-ops-not-tailwind-ops
description: A plain Tailwind v4 container-query question with no component library does not load shadcn-ops
tags: [near-miss, shadcn-ops]
runs: 3
max_turns: 4
timeout_seconds: 180
allowed_tools: [Skill, Read, Glob, Grep]
---

In plain Tailwind CSS v4 (no component library), how do I make a card grid switch from one to three columns based on its container's width rather than the viewport, and where do custom breakpoints for that go now that there's no tailwind.config.js?
