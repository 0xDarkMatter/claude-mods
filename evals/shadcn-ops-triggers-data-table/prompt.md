---
name: shadcn-ops-triggers-data-table
description: A sortable, paginated orders table with row actions on shadcn/ui loads shadcn-ops
tags: [trigger, shadcn-ops]
runs: 3
max_turns: 4
timeout_seconds: 180
allowed_tools: [Skill, Read, Glob, Grep]
---

I'm building an orders page for our dashboard with shadcn/ui. It needs a table with sorting, a status filter, pagination done on the server because there are a few hundred thousand rows, row selection and a menu on each row with "refund" and "view details". How do I set this up?
