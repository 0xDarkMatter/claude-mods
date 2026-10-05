# Daemon Lifecycle

How the optional landing daemon starts, stops and polls, and why it never exits from inside its signal handler.

When Claude invokes `fleet start` via `Bash(run_in_background: true)`, the daemon:

1. Writes its PID to `.claude/fleet/daemon.pid`
2. Treats `SIGTERM`/`SIGHUP` (and `SIGINT`, where it is trappable) as a **stop request**: a land already in progress finishes, test gate included; no new land starts; then it exits and removes the PID file. An idle daemon answers during its poll sleep, not after it
3. Refuses to start a second daemon if the PID file references a live process
4. Polls `.claude/fleet/lanes/` and lands lanes as they turn `READY`
5. Exits naturally when all lanes are terminal (`LANDED` or `FAILED`)

It never exits from inside the signal handler: bash runs a trap *between* commands, so that exit could fall between `git merge` and the gate and leave an untested merge on `main`. Until 2026-09-28 the handler removed the PID file and then *resumed*. A daemon whose session ended (SIGHUP) kept polling as a ghost, invisible to `fleet stop` and the double-start guard, and landed lanes 3s later.

To stop early: `fleet stop` (SIGTERM, 5s grace, then SIGKILL). **Caveat:** the SIGKILL escalation does not know about a land in progress, so stopping while a gate slower than 5s runs kills the daemon mid-gate and leaves that merge on `main` untested. Check `activity.log` for a `running test_cmd:` line without its `PASS`/`FAIL` before stopping, and let it finish. On next `fleet start`, a stale PID file is auto-detected and cleared. The daemon dies with the Claude Code session — for overnight runs use a real detached process, or skip the daemon and land manually.
