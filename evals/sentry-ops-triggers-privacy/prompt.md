---
name: sentry-ops-triggers-privacy
description: Stopping personal data reaching Sentry after an SDK upgrade loads sentry-ops
tags: [trigger, sentry-ops]
runs: 3
max_turns: 4
timeout_seconds: 180
allowed_tools: [Skill, Read, Glob, Grep]
---

We set sendDefaultPii to false years ago, but after upgrading the SDK our Sentry events show request bodies and client IPs. How do we stop personal data going out, and how can we confirm what is being sent?
