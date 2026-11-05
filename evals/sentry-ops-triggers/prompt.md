---
name: sentry-ops-triggers
description: Adding Sentry error reporting to a site on Cloudflare Workers loads sentry-ops
tags: [trigger, sentry-ops]
runs: 3
max_turns: 4
timeout_seconds: 180
allowed_tools: [Skill, Read, Glob, Grep]
---

I want error reporting from Sentry on an Astro site that runs on Cloudflare Workers. Which package do I install, what should I change from the setup snippets, and how do I check it works before real errors start flowing?
