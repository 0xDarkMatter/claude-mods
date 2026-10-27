<!-- Recorded excerpt of https://docs.boat.dev/limits.md, fetched 2026-10-27. Test input for check-boat-facts.py --live --fixtures; lines are verbatim, the rest of the page is cut. -->
# Limits and errors

| Auto-stop | Default 1 hour. Maximum 30 days, or off. Trial: 2 hours maximum. |
| Command that waits for its result | API: default timeout 30 s, maximum 600 s. For longer work, run it detached. No maximum with `boat exec --timeout 0` (CLI) or `run_command` / `runCommand` (SDK). |
| Output of a waiting command | 8 MiB per stream |
| API keys | Lifetime 90 days by default, 365 days maximum, or never expires (`--ttl never`) |
