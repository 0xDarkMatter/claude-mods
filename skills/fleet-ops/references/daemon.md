# Daemon Lifecycle

How the optional landing daemon starts, stops and polls, why it never exits from inside its signal handler, and why `fleet stop` never SIGKILLs it mid-land.

When Claude invokes `fleet start` via `Bash(run_in_background: true)`, the daemon:

1. Writes its PID to `.claude/fleet/daemon.pid`
2. Treats `SIGTERM`/`SIGHUP` (and `SIGINT`, where it is trappable) as a **stop request**: a land already in progress finishes, test gate included; no new land starts; then it exits and removes the PID file. An idle daemon answers during its poll sleep, not after it
3. Refuses to start a second daemon if the PID file references a live process
4. Polls `.claude/fleet/lanes/` and lands lanes as they turn `READY`
5. Exits naturally when all lanes are terminal (`LANDED` or `FAILED`)

It never exits from inside the signal handler: bash runs a trap *between* commands, so that exit could fall between `git merge` and the gate and leave an untested merge on `main`. Until 2026-09-28 the handler removed the PID file and then *resumed*. A daemon whose session ended (SIGHUP) kept polling as a ghost, invisible to `fleet stop` and the double-start guard, and landed lanes 3s later.

To stop early: `fleet stop`. It sends SIGTERM and waits. While the daemon is mid-land, `fleet stop` waits as long as the gate takes, printing which lane it is waiting on, and **never escalates**. The daemon records that land in `.claude/fleet/landing` from just before the merge until the follow-up rebase pass is done. Only an idle daemon that still ignores SIGTERM after 5s gets SIGKILL. Until 2026-10-05 that 5s clock ran regardless, so any gate slower than 5s was killed mid-run: the merge stayed on `main` untested, and the next pass's "already up to date" path marked the lane `LANDED` anyway.

- **Interrupting `fleet stop` is safe**: the request is already delivered, and the daemon exits once the land finishes.
- **To abort a hung gate**, kill the `test_cmd` process, not the daemon. The gate fails, the merge is rewound, and the daemon exits.
- **From an agent's Bash tool**, a slow gate can outlast the tool timeout. Run `fleet stop` in the background, or with a timeout longer than the gate.

On next `fleet start`, a stale PID file is auto-detected and cleared. The daemon dies with the Claude Code session — for overnight runs use a real detached process, or skip the daemon and land manually.
