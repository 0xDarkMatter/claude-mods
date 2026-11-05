<!-- Recorded excerpt of https://vercel.com/docs/sandbox/pricing.md, fetched 2026-11-05. Test input for check-sandbox-facts.py --live --fixtures; lines are verbatim, the rest of the page is cut. -->
title: Vercel Sandbox pricing and quotas
The default timeout is 5 minutes. You can configure this using the `timeout` option when creating a sandbox, and extend it using `sandbox.extendTimeout()`. See [Working with Sandbox](/docs/sandbox/working-with-sandbox#execute-long-running-tasks) for details.
| Max Session Duration | 45 minutes | 24 hours | 24 hours |
Snapshots expire **30 days after their last use by default**. You can configure the [expiration time](/docs/sandbox/concepts/snapshots#snapshot-retention) to control how long snapshots are retained, including removing the expiration so they are kept indefinitely.
Deleting a sandbox, snapshot, or drive is limited to 20 requests per second per team on all plans. Deletions count against your control plane quota as well.
