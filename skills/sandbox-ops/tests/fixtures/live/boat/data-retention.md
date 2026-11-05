<!-- Recorded excerpt of https://docs.boat.dev/data-retention.md, fetched 2026-10-27. Test input for check-boat-facts.py --live --fixtures; lines are verbatim, the rest of the page is cut. -->
# Data retention and deletion

| Newest snapshot of a stopped sandbox | **14 days after the stop.** boat emails you on day 11. Then it deletes the data, and resume and fork fail with `409 snapshot_data_expired` ([details](https://docs.boat.dev/snapshots/stop.md#keep-a-stopped-sandbox-longer-than-14-days)) |
| Command history: `boat exec` and API commands, with output | 90 days |
| With snapshots off | Nothing. A stop erases the sandbox ([details](https://docs.boat.dev/data-retention/snapshots-and-monitoring-off.md#snapshots-off)) |
