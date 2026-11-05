---
name: sandbox-ops-triggers
description: Running a slow test suite on a boat.dev box and cleaning up after loads sandbox-ops
tags: [trigger, sandbox-ops]
runs: 3
max_turns: 4
timeout_seconds: 180
allowed_tools: [Skill, Read, Glob, Grep]
---

My laptop can't cope with this repo's full test suite. I'd like to boat new a box on boat.dev, copy the repo over, run the tests there and bring the results back. What's the safe way to do it, and how do I make sure the box is really gone afterwards?
