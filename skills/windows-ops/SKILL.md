---
name: windows-ops
description: "Comprehensive Windows workstation operations - diagnose slow boot, failing drives, BSOD crashes, startup bloat, runaway processes, event logs. Use for: Windows is slow, slow bootup, won't boot, blue screen, BSOD, kernel crash, drive failing, SMART errors, disk errors, Event 41, Event 129, storahci reset, BugCheck, CRITICAL_PROCESS_DIED, crash dump, MEMORY.DMP, minidump, msconfig, services.msc, registry Run keys, StartupApproved, scheduled tasks at logon, slow login, high CPU at boot, disable startup app, unexplained UAC prompt, what asked for admin, prefetch forensics, BAM, process attribution, Security 4688, high CPU, runaway process, spinning process, process eating CPU, memory commit exhausted, out of memory, too many processes, what is using my RAM, orphaned process, stale processes, zombie process, kill a process tree, machine is hot, fans are loud. A drive letter alone does not name the skill: mapped network drive, SMB, UNC, NAS route to net-ops."
license: MIT
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
  related-skills: net-ops, debug-ops, perf-ops
---

# windows-ops

## Helps with

Slow or worsening boot, silently failing drives, crashes with no obvious cause, an HKLM startup entry you can't disable without admin, BSODs that leave no dump, unexplained UAC prompts, 'is it safe to unplug this drive?', cloning a failing drive, no-boot recovery, remote diagnostics, and a hot or out-of-commit machine with no boot-time explanation. Where each signal lives: [references/symptom-guide.md](references/symptom-guide.md).

## The Universal Insight

**Windows tells you what's wrong if you ask the right log in the right way.** Most users (and most tutorials) reach for Task Manager. The actual diagnostic signal lives in the Event Log, the Registry's StartupApproved key, the storage driver's reset events, and the kernel's bugcheck records. This skill packages the queries that turn noise into a verdict.

The most common diagnostic failure: treating symptoms in isolation. "Slow boot" → disable startup apps. "BSOD" → reinstall drivers. "Random crashes" → memtest. These are reasonable last resorts, but the data to identify the *actual* cause is sitting in the System log untouched. Always audit before treating.

## The Diagnostic Ladder

Walk down the layers in order. Each rung has a binary outcome:

```
0. Is it even local?  — a "drive" that is a network mapping belongs to net-ops
1. Hardware errors    — WHEA-Logger events (CPU/RAM/PCIe-level faults)
2. Storage health     — disk events 7/52/153/154, storahci 129 (controller reset)
3. Crash record       — Event 41 (Kernel-Power) + BugCheck code + dump files
4. Pre-crash timeline — events in N minutes before each crash
5. Boot inventory     — all 5 startup mechanisms (registry, services, tasks, folders, group policy)
6. Resource pressure  — CPU RATE sample, commit hoarders, orphans, stale hosts
7. Verdict            — what's failing, what to do
```

The most interesting failures cluster at rung 2 (storage) and rung 5 (startup bloat). Rung 6 is the most-treated and the most *misread*: a Task Manager **snapshot** there really is low-value, which is why it gets waved away — but a CPU **rate** sample at the same rung finds hung processes no snapshot and no orphan check can see.

## Workflow

### 0. Disambiguate the drive letter first

A user saying "drive Z: is broken" cannot know whether that is a failing physical disk (this skill) or an SMB/name-resolution fault (`net-ops`) — the drive letter looks identical either way. Settle it before running anything else:

```powershell
Get-SmbMapping                            # network mappings + Status (Connected / Disconnected / Unavailable)
Get-PSDrive -PSProvider FileSystem | Where-Object DisplayRoot   # non-empty DisplayRoot = UNC-backed
```

**If the letter appears in either result, it is a network mapping — stop here and hand off to `net-ops` (`scripts/windows/smb-audit.ps1`).** Do not run the physical-disk ladder: `disk-health.ps1` and `drive-dependencies.ps1` only see local disks, so they will report a clean bill of health on a drive that is genuinely broken, which is worse than reporting nothing.

Everything below assumes a local, physically-attached drive.

### 1. Run the comprehensive audit

```powershell
scripts/health-audit.ps1
```

Produces a verdict block: hardware errors, storage health per disk, recent crashes, top resource consumers, startup inventory. Scan for `[FAIL]` markers — that's where to drill.

### 2. Drill into the failing layer

| Symptom | Script |
|---|---|
| Storage errors flagged | `scripts/disk-health.ps1 -DiskNumber N` (or `-DriveLetter X` or `-Model 'HGST'`) — focused per-drive deep dive: SMART, all event IDs, controller resets attributable to the drive, verdict |
| Recent crash | `scripts/crash-triage.ps1 -CrashTime <datetime>` (or omit for most recent) — pre-crash timeline + BugCheck decode with smoking-gun detection |
| "Is it safe to disconnect drive X?" | `scripts/drive-dependencies.ps1 -DriveLetter X` — finds pagefile, search index, scheduled tasks, services, symlinks, startup shortcuts, run-key refs pointing at drive |
| "Why is boot taking so long?" | `scripts/boot-perf.ps1` — per-boot durations from Diagnostics-Performance log (admin) or kernel-event fallback (non-admin), with slow-component flags |

### 3. Apply the minimum reversible fix

| Action | Script |
|---|---|
| Disable startup app — Run keys (HKCU + HKLM + WOW64) | `scripts/safe-disable-startup.ps1 -Name <pattern>` (no admin needed; supports wildcards) |
| Disable startup folder shortcut | `scripts/safe-disable-startup.ps1 -Name '*.lnk'` (covered by same script via StartupFolder variant) |
| List current state of all startup entries | `scripts/safe-disable-startup.ps1 -List` |
| Re-enable previously disabled | `scripts/safe-disable-startup.ps1 -Name <pattern> -Enable` |
| Set service to Manual (admin) | `Set-Service <name> -StartupType Manual; Stop-Service <name>` |
| Disable scheduled task | `Disable-ScheduledTask -TaskName <name>` |
| Copy a folder tree, never stopping on errors | `scripts/copy-tree.ps1 <src> <dst>` — additive, one retry per file, readable failed-files log; exit 10 = some files failed |
| Safe clone from failing drive | `scripts/copy-tree.ps1 <src> <dst> -Mode Rescue` — robocopy with `/R:0 /W:0 /MT:1` so retries do not pound bad sectors |
| Mirror a folder (DELETES extras at destination) | `scripts/copy-tree.ps1 <src> <dst> -Mode Mirror` — prompts unless `-Force` |
| Drive too damaged for file-level copy | `scripts/rescue-image.ps1 -ListDevices` then `-Device <dev> -Image <path>` — ddrescue, supervised, resumable via mapfile |
| Get files back out of a rescue image | `scripts/extract-image.ps1 -Image <img> -Plan` then `-Extract -Dest <dir> -Include <pat>` — 7-Zip, read-only, no mount needed |

All disables are reversible — the StartupApproved registry mechanism flips one byte; re-enabling is the inverse.

## Storage Health & Failure Detection

The single highest-yield audit. Failing drives cause slow boots (Windows times out probing them), instability (controller resets cascade into kernel hangs), and crashes (I/O failures kill critical processes). Three independent data sources to cross-reference:

Disk Events **7** (bad block) and **154** (hardware error) are the high-severity IDs: even 10 in a month is a strong failure signal, hundreds means replace now. `storahci` Event **129** (controller reset): healthy is zero, more than 5 a month is active failure. `\Device\HarddiskN` is `Get-Disk` number N. `scripts/disk-health.ps1` runs all three; the manual queries, event catalogue and SMART fallbacks: [references/manual-queries.md](references/manual-queries.md).

## Boot Performance & Startup Management

Windows has **five separate startup mechanisms**, each requiring different tooling. Task Manager only shows two of them. Full inventory in `references/startup-mechanisms.md`.

| Mechanism | Where | How to inspect | How to disable |
|-----------|-------|----------------|----------------|
| Registry Run keys | `HKCU/HKLM\...\Run` (+ WOW6432) | `Get-ItemProperty` | `StartupApproved` binary flag |
| Services | Service Control Manager | `Get-Service` | `Set-Service -StartupType Manual` (admin) |
| Scheduled Tasks at logon | Task Scheduler | `Get-ScheduledTask` | `Disable-ScheduledTask` |
| Startup folder shortcuts | `%APPDATA%\...\Startup\` + AllUsers | `Get-ChildItem` | Delete or rename .lnk |
| Group Policy startup scripts | `HKLM\...\Policies\Scripts` | Group Policy Editor / `gpresult` | (rare on workstations) |

Task Manager's Disable writes a 12-byte `StartupApproved` flag under HKCU (`0x02` enabled, `0x03` disabled), so a non-admin can disable HKLM entries for themselves; `scripts/safe-disable-startup.ps1` does it. Boot timing lives in the admin-only Diagnostics-Performance log (`scripts/boot-perf.ps1` falls back to kernel events): healthy SSD 15–25 s to login, failing storage 60 s and up. Detail: [references/manual-queries.md](references/manual-queries.md).

## Crash Analysis & Dump Triage

Event 41 (Kernel-Power) is the crash record: `Properties[0]` is the BugCheck code (`0x0` = none recorded, so hard power loss or a hang) and a non-zero index 6 means the power button was held. The 10 minutes before it hold the story: `storahci` 129 → storage cascade, GPU driver warnings → driver hang, WHEA → hardware fault, silence → total hang (`scripts/crash-triage.ps1 -CrashTime …`). No dumps after crashes → check `CrashControl\CrashDumpEnabled` and pagefile size. Layout and decoding tables: [references/manual-queries.md](references/manual-queries.md); stop codes: `references/bugcheck-codes.md`.

## Runaway Process Triage

Steady-state, not boot-time — something is burning the machine *right now*. The
whole discipline is one correction: **measure the rate, not the lineage.**

Cumulative CPU tells you what a process has *ever* done. An orphan scan tells you
whose parent died. Neither finds the expensive case — a stuck process whose
supervisor is alive and well, spinning near a full core and producing nothing.

```powershell
scripts/process-triage.ps1                                 # sample all, flag >=20% of a core
scripts/process-triage.ps1 -Name claude,node -Threshold 50 # hunt agent/editor spinners
scripts/process-triage.ps1 -Json | ConvertFrom-Json        # machine-readable findings
scripts/process-triage.ps1 -Tree 35736                     # what a kill takes, leaves-first
```

Exit `10` = findings, `0` = clean. Two CPU samples across a window give
percent-of-one-core alongside private commit, age and orphan status. **It never
terminates anything** — `-Tree` emits an ordered list so the caller acts
deliberately.

**The guard that matters.** The script resolves *this session's own ancestry* —
shell → agent host → application — before reporting, and marks every hop
`protected=True`. Killing any of them ends the session doing the investigation,
so that hop must never be indistinguishable from a candidate. Doing this by hand
means walking your own PID up through `ParentProcessId` **first**, before you
look at anything else.

Then terminate **leaves-first**: deepest descendants before their supervisor, so
a live parent cannot respawn a child you already reaped. Later entries reporting
"already gone" is the cascade working, not an error. Killing a process never
deletes files — uncommitted work in its directory survives untouched.

**Report commit, not RAM.** Windows exhausts *commit* (RAM + pagefile guarantees,
`Win32_OperatingSystem.FreeVirtualMemory`) before it exhausts physical memory, so
a box with free RAM can still refuse to start anything. Quote before/after for
process count, private commit, and machine commit free — freeing commit often
recovers more than the sum of what you killed.

Depth — the three failure classes, the triage ladder, Electron/agent-host
topology, stale-build detection, and the worktree-teardown case — is in
[`references/process-triage.md`](references/process-triage.md).

## Event Log Query Patterns

Filter with `Get-WinEvent -FilterHashtable` (far faster than `Where-Object`); the keys that work: [references/manual-queries.md](references/manual-queries.md).

## Common Failure Modes

| Symptom | First check | Common cause |
|---------|-------------|--------------|
| Mapped drive shows `Disconnected` / UNC path unreachable | Is this a network mapping? `Get-SmbMapping` | Hand to `net-ops` — not a local storage fault |
| Slow boot, used to be fast | `startup-audit.ps1` | Bloat accumulation (Docker, Adobe CC, Electron apps) |
| Slow boot, getting worse | `disk-health.ps1` | Failing drive — Windows waiting on probe timeouts |
| Random freezes + hard restarts | `disk-health.ps1` + `crash-triage.ps1` | storahci resets cascading into kernel hang |
| BSOD on wake from sleep | `crash-triage.ps1` (BugCheck `0x9F`) | Driver power state failure (often GPU, USB) |
| BSOD with WHEA before it | `crash-triage.ps1` (BugCheck `0x124`) | Hardware fault — RAM, CPU, PCIe lane |
| Sluggish but not crashing | `health-audit.ps1` performance section | Background process pileup |
| Login takes minutes | `startup-audit.ps1` | Slow startup item synchronously blocking shell |

## Recovery Patterns

### Cloning from a failing drive

**Never run `chkdsk /f` on a failing drive** — repair operations write to bad sectors and can finish the drive off. Image first, repair the image second.

```powershell
# Healthy-side clone with no retries (fast, skips bad sectors)
robocopy "Y:\important" "Z:\backup\important" /MIR /R:0 /W:0 /XJ /NDL /LOG:clone.log
```

For bit-level recovery from a drive with many bad sectors, use `ddrescue` (via WSL or live Linux USB) with a map file so the operation is resumable. Documented in `references/storage-events.md`.

### Physically removing a failing drive

If a drive is causing boot stalls or crashes:
1. Identify it via `disk-health.ps1`
2. Verify nothing critical points at it (`scripts/disk-health.ps1 -CheckDependencies <drive-letter>`)
3. Physically disconnect SATA cable OR disable in BIOS OR set offline in `diskpart`
4. Reboot — boot time should drop significantly, controller resets should stop

## Voice & Output Style

Output follows the claude-mods diagnostic convention:

- `[PASS]` / `[FAIL]` / `[WARN]` / `[INFO]` prefixes for scan rows
- Verdict block at the bottom with specific findings + recommended actions
- Drive identifications include physical disk number, model, capacity, drive letter
- Crash references include UTC timestamp, BugCheck code, primary parameter, suspected cause
- No marketing language, no emojis in scripts (reserved for SKILL.md prose where useful)

## What This Skill Doesn't Cover

- **Network diagnostics, including anything storage-shaped that turns out to live on the network** → use `net-ops`. Concretely: a mapped network drive, a mapping stuck `Disconnected` / `Unavailable`, a UNC path (`\\server\share`) that won't open, SMB itself, a NAS or Synology box, `net use` failures, and "access is denied" on a share. A drive letter does not make it local.
- **Application performance profiling** (flamegraphs, py-spy/pprof, load tests, slow queries) → use `perf-ops`. The split: windows-ops triages *the workstation* — which process is burning the box and is it safe to kill; perf-ops profiles *inside* a program you are optimising.
- **Source-code-level debugging** → use `debug-ops`
- **Kernel dump file analysis with WinDbg** — too specialised for this skill; covered by reference doc pointers only
- **Group Policy diagnostics** — relevant for enterprise but rare on workstations
- **Linux-on-Windows (WSL) issues** — separate domain

## Cross-References

| When | Use |
|------|-----|
| The failing "drive" is a network mapping / NAS share (SMB, UNC, `Disconnected`) | `net-ops` owns it — `scripts/windows/smb-audit.ps1` for the mapping + SMB/LAN ladder |
| Need to triage a remote Windows box | `net-ops` reverse-probe pattern adapts directly |
| Crash is networking-related | Combine with `net-ops` for DNS / VPN driver issues |
| Multiple machines exhibit same pattern | Run `health-audit.ps1` on each, diff the outputs |
| A flagged spinner names a git worktree that no longer exists | `fleet-ops` owns worktree lifecycle — [the teardown-ordering landmine](../fleet-ops/SKILL.md#landmine-removing-a-worktree-out-from-under-a-live-session) |
| Need to profile inside an app rather than triage the box | `perf-ops` |

## References

- `references/storage-events.md` — disk and controller event IDs, failure thresholds
- `references/bugcheck-codes.md` — BSOD stop codes and their likely causes
- `references/startup-mechanisms.md` — the five startup mechanisms, vendor auto-launch hooks
- `references/recovery-patterns.md` — data recovery, the chkdsk decision tree, BCD and no-boot repair; load before anything destructive
- `references/uac-attribution.md` — what asked for admin, in the moment and after the fact
- `references/process-triage.md` — spinners, orphans, hoarders; safe termination order
- `references/remote-diagnostics.md` — running this skill against a remote box
- `references/symptom-guide.md` — symptom to signal, by complaint
- `references/manual-queries.md` — the queries and decoding tables the scripts automate
- `references/worked-example.md` — one failing-drive case end to end

When to load each, in full: [references/reference-index.md](references/reference-index.md).

## Worked example

A slow-booting, crashing PC taken through the `health-audit.ps1`, `disk-health.ps1` and `drive-dependencies.ps1` panels, then the fix loop. Every script takes `-Json` (for `jq`) and `-Verbose`, and drops panel chrome when piped. Panels and the full command sequence: [references/worked-example.md](references/worked-example.md).
