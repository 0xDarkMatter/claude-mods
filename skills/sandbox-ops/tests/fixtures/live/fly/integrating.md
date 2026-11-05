<!-- Recorded excerpt of https://docs.fly.io/flyctl/integrating.md, fetched 2026-11-05. Test input for check-sandbox-facts.py --live --fixtures; lines are verbatim, the rest of the page is cut. -->
# Integrating flyctl
When this variable is set, flyctl skips all interactive auth prompts and uses the token for every command. It takes precedence over the token saved by a prior `fly auth login`. flyctl also honors `FLY_ACCESS_TOKEN` as an alternative name for the same value. If both variables are set, `FLY_ACCESS_TOKEN` takes precedence.
