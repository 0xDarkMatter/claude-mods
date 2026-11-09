---
name: shadcn-ops-triggers
description: Building an admin settings form in a project with components.json loads shadcn-ops
tags: [trigger, shadcn-ops]
runs: 3
max_turns: 4
timeout_seconds: 180
allowed_tools: [Skill, Read, Glob, Grep]
---

My Next.js app uses shadcn/ui (there's a components.json with the base-nova style and lucide icons). I need a settings form for the admin area with full name, email and notification preferences for email, SMS and push, plus validation errors on the required fields. Which components should I add, and how should the form be structured?
