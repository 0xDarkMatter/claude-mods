# Process Triage — runaway, orphaned and stale processes

Steady-state companion to the boot-time material in
[startup-mechanisms.md](startup-mechanisms.md). That file answers *"what starts
at logon"*; this one answers *"what is eating the machine right now, and is it
safe to kill"*.

Load this when a workstation is hot, loud, or out of commit, and the cause is a
process that is already running rather than one that is about to start.

---

## The three failure classes

They look identical in Task Manager and need different evidence.

| Class | Signature | How you find it |
|---|---|---|
| **Spinner** | Burning CPU continuously, producing nothing. Parent usually **alive**. | CPU **rate** over a sampling window |
| **Orphan** | Parent PID no longer exists. May be idle or busy. | `ParentProcessId` not in the live PID set |
| **Hoarder** | Low CPU, large private commit. Many instances of one image. | `PageFileUsage` summed per image |

The trap is assuming these are the same problem. A spinner with a live parent is
invisible to an orphan scan, and an orphan burning no CPU is invisible to a rate
scan. Run the rate sample first — it is the only one that finds the expensive
case.

## Why rate, and not lineage

**The most expensive processes on a workstation usually have a perfectly healthy
parent.** A supervisor (an editor host, an agent runtime, a shell) spawns a
child; the child gets stuck; the supervisor keeps running and never reaps it.
Every "find orphaned processes" recipe reports nothing, because nothing is
orphaned.

Measured on this machine, 2026-08-30: a dead-parent orphan scan returned **3
processes totalling 1.16 GB**, while **six spinners with live parents held five
cores** and had burned **66.6 core-hours over 43.8 hours**. The orphan scan was
not wrong; it was answering a different question.

Sample twice, subtract, divide by the window:

```
core_pct = (cpu_seconds_after - cpu_seconds_before) / window_seconds * 100
```

A sustained result near 100 is one saturated core. Anything above ~20 that
persists across two samples and produces no output is a spinner until proven
otherwise. Use `scripts/process-triage.ps1`, which does this plus the safety
work below.

**Never trust a single snapshot.** Cumulative CPU seconds tell you what a process
has *ever* done, not what it is doing — a process that spun yesterday and is now
idle looks identical to one spinning right now.

## Commit is the ceiling, not working set

Windows fails on **commit**, not on RAM. Commit is what every process has asked
the memory manager to guarantee (RAM + pagefile); working set is only what is
resident at this instant. A machine with free RAM can still refuse to start
processes because the commit limit is reached.

- Per process: `Win32_Process.PageFileUsage` (KB) — private commit.
- Machine: `Win32_OperatingSystem.TotalVirtualMemorySize` / `FreeVirtualMemory`.

Report commit when the complaint is "out of memory" or "can't start anything";
report working set only when asked about physical pressure. Freeing commit often
recovers **more** than the sum of what you killed, because shared and
pagefile-backed allocations are released alongside.

## The triage ladder

Stop at the first rung that explains the symptom.

1. **Establish the baseline.** Process count, total commit for the suspect image,
   machine commit free. Without a before-number you cannot report a result.
2. **Rate-sample.** `process-triage.ps1 -Sample 10`. Anything at/above threshold
   is the shortlist. Exit 10 means findings.
3. **Classify each hit.** Orphan? Age? Does its work target still exist (a
   directory, a mount, a port, a socket)? A process retrying against something
   deleted is the classic silent spinner.
4. **Attribute.** Read the full command line. `--add-dir`, `--config`, a script
   path, or a profile directory usually names the owner immediately.
5. **Check for a stale host.** Multiple instances of a supervisor from
   *different build versions* means an old one never restarted after an update.
   A supervisor whose whole tree owns **no window** is a strong zombie signal.
6. **Terminate deliberately** — see below.

## Safe termination

Four rules, in order. The first is the one that ends sessions.

1. **Resolve your own ancestry first and never kill inside it.** Walk from your
   own PID up through `ParentProcessId` to the root and treat every hop as
   untouchable. Your shell, its host, and the application hosting the agent are
   all in that chain — killing any of them ends the session doing the
   investigation. `process-triage.ps1` marks these `protected=True` and warns
   when a requested tree contains them.
2. **Enumerate the tree before you touch it.** `process-triage.ps1 -Tree <pid>`
   returns every descendant with a commit total and a `kill_order`.
3. **Leaves-first.** Terminate deepest descendants before their supervisor, so a
   still-live parent cannot respawn a child you already reaped. Expect a large
   share of "failures" on the later entries — children exit in the cascade before
   their turn, and that is success, not error.
4. **Verify, don't assume.** Re-sample after the kill. A tree is only finished
   when the root is gone *and* no descendant survives.

**Killing a process does not delete files.** Uncommitted work in a directory the
process was using stays exactly where it was. What is lost is unflushed
in-memory state — which, for a spinner, is nothing worth keeping.

## Claude Code and Electron hosts

Agent and editor hosts produce the largest trees on a developer workstation, and
they have a topology worth knowing.

- An Electron application is one **main** process plus renderer/GPU/utility
  children. The main process is the one to reason about; the children follow it.
- **A main process whose entire tree owns no window is a zombie.** Check
  `MainWindowTitle` across the whole tree, not just the root — a minimised or
  tray-resident app still reports a title somewhere in its tree.
- After an application update, the **old build keeps running** until it is
  restarted. Two instances on different version paths is normal immediately
  after an update and stale a day later. Compare the version segment in each
  main process's image path.
- Agent sessions can live under **separate profile directories**
  (`CLAUDE_CONFIG_DIR`-style installs). The profile path in the command line
  tells you which account or configuration a session belongs to.
- Session transcripts are the liveness ground truth. If a host holds dozens of
  sessions but only a handful of transcripts were written in the last few hours,
  most of those sessions are resident rather than active.

## The worktree-teardown case

The most reproducible way to manufacture a spinner is to delete the directory a
live session is working in. The session does not exit and does not error — it
retries forever.

If a flagged process names a working directory in its command line, check that
the directory still exists, and for a git worktree that it is still registered:

```powershell
process-triage.ps1 -Name claude -Threshold 50 -Json | ConvertFrom-Json |
  ForEach-Object { $_.data } | Where-Object { $_.command -match '--add-dir' }
```

A target missing from both the filesystem and `git worktree list` is conclusive.

The ordering rule that prevents it — terminate the session, *then* remove its
worktree — is recorded as a landmine in
[fleet-ops](../../fleet-ops/SKILL.md#landmine-removing-a-worktree-out-from-under-a-live-session),
which owns worktree lifecycle. This file owns the diagnosis; that one owns the
prevention.

## Reporting the result

A cleanup is not finished until it is quantified. Report before/after for:

- process count for the affected image
- private commit for those processes
- **machine commit free** — the number that was actually constraining the box
- cores recovered, if spinners were involved

Without the after-number you have a claim; with it you have a result.
