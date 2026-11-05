---
name: sandbox-ops-not-cloudflare-sandbox
description: Writing a Worker that uses the @cloudflare/sandbox SDK belongs to Cloudflare's sandbox skills, not sandbox-ops
tags: [near-miss, sandbox-ops]
runs: 3
max_turns: 4
timeout_seconds: 180
allowed_tools: [Skill, Read, Glob, Grep]
---

Write me a Cloudflare Worker that uses the @cloudflare/sandbox package: on a POST it should start a sandbox from the Durable Object binding, run the Python snippet in the request body with exec, and return stdout as JSON. Show the wrangler.jsonc bindings too.
