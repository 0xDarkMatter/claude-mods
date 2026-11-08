---
name: sentry-ops-not-monitoring-ops
description: A Prometheus and Grafana alerting question does not load sentry-ops
tags: [near-miss, sentry-ops]
runs: 3
max_turns: 4
timeout_seconds: 180
allowed_tools: [Skill, Read, Glob, Grep]
---

Our API needs a latency SLO. How should I set up Prometheus recording rules and a Grafana dashboard, and when should an alert page someone?
