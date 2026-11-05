<!-- Recorded excerpt of https://www.daytona.io/docs/en/sandboxes.md, fetched 2026-11-05. Test input for check-sandbox-facts.py --live --fixtures; lines are verbatim, the rest of the page is cut. -->
# Sandboxes
By default, Daytona sandboxes auto-stop after 15 minutes of inactivity. To keep a sandbox running without interruption from inactivity, set the auto-stop interval to `0` when creating a new sandbox. Disabling auto-stop does not disable [wall-clock TTL](#wall-clock-ttl): if `ttl_minutes` is set, the sandbox is still destroyed when that deadline elapses.
If you run a long-running task like LLM inference that takes more than 15 minutes to complete without any external interaction, the sandbox may auto-stop mid-process because the process itself doesn't count as "activity", therefore the timer is not reset.
Sandboxes have **1 vCPU**, **1GB RAM**, and **3GiB disk** by default. Organizations get a maximum sandbox resource limit of **4 vCPUs**, **8GB RAM**, and **10GB disk**.
