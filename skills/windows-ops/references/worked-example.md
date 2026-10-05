# Worked Example: a Failing Drive, End to End

One slow-booting, crashing PC taken from the first audit to a verified fix, with the panels each script renders.

## Worked example

A user reports "my PC takes minutes to boot and crashes sometimes." Running `scripts/health-audit.ps1` produces a panel that follows the [Terminal Panel Design System](../../../docs/TERMINAL-DESIGN.md):

```
╭── 🩺 windows-ops · health-audit ──────────────────────────────────────────── WORKSTATION ───●
│
├── 4 disks · 1 failing · 2 unclean shutdowns
│
├── failing (5)
│   ├── [storage] Disk 1 (HGST HDN728080ALE6…   Failing: Event7=1943, Event154=1646 …
│   ├── [storage] Controller resets             20 storahci controller resets in 60d
│   ├── [crash] 2026-05-15 00:57                BugCheck=0x0 — hard power loss
│   ├── [crash] 2026-05-11 00:12                BugCheck=0x0 — power button held
│   └── [crash] Pattern                         2 unclean shutdowns — investigate PSU
│   │   ▲ back up + disconnect Disk 1 (Y) — see copy-tree.ps1 and drive-deps.ps1
│
├── warn (2) · pass (7) · info (4)
│
╰── R refresh · D drill · ? help ──────────────────────── ⬤ storage  • 2 crashes ───●
```

The verdict reads at a glance: storage is busted (⬤ — large, unmissable), two crashes recent (•), specific drive identified by `[Y]`, action items inlined under the critical alert with cross-script wayfinding. Drill into the suspect:

```
╭── 🩺 windows-ops · disk-health ──────────────────────────────────── Disk 1 / Y ───●
│
├── HGST HDN728080ALE604 · A4GNW91X · 7452 GB · HDD/SATA
│
├── FAILING (3)
│   ├── Event 7 (bad block)              ▰▰▰▰▰▰▰▰▰▰      1943x
│   ├── Event 154 (hw error)             ▰▰▰▰▰▰▰▰▰▰      1646x
│   └── Controller resets                ▰▰▰▰▰▰▰▰▱▱      20x
│   │   ▲ back up data, run drive-dependencies.ps1, then replace
│
╰── B back · C clone · ? help ────────────────────────────────────── ⬤ failing ───●
```

Pip bars show how many times over threshold each indicator runs. Before disconnecting, audit dependencies:

```
╭── 🩺 windows-ops · drive-dependencies ─────────────────────────────────── Y ───●
│
├── 0 system references · safe to disconnect
│
│   💡 no system mechanism references this drive
│
╰── B back · ? help ────────────────────────────────────────────────── • safe ───●
```

Three commands, three panels, complete decision tree. Then the same loop: `crash-triage.ps1` decodes the most recent crash with a T-relative pre-crash timeline; `safe-disable-startup.ps1 -List` panel-displays every Run-key / StartupFolder entry grouped by state; `copy-tree.ps1 Y:\important Z:\rescue -Mode Rescue` clones with `robocopy /R:0 /W:0 /MT:1` so retries don't accelerate the drive's death; `boot-perf.ps1` quantifies boot duration with capacity pip bars.

The data was always there in the System log — this skill just asks for it correctly *and renders it like a proper instrument*.

### Legacy workflow notes

For non-panel verbose tracing add `-Verbose`. For machine-readable consumers add `-Json` (all scripts emit NDJSON / JSON suitable for `jq`). For piped contexts (no TTY) chrome rendering disables itself automatically and JSON-only output is appropriate.

Full command sequence:

```powershell
scripts/health-audit.ps1                            # diagnose
scripts/disk-health.ps1 -DriveLetter Y              # drill into suspect
scripts/crash-triage.ps1                            # decode most recent crash
scripts/drive-dependencies.ps1 -DriveLetter Y       # verify safe to disconnect
scripts/copy-tree.ps1 Y:\ Z:\rescue -Mode Rescue     # salvage data
scripts/safe-disable-startup.ps1 -List              # audit startup state
scripts/safe-disable-startup.ps1 -Name 'Adobe*','Granola','MuseHub'  # cull bloat
Set-Service AdobeARMservice -StartupType Manual     # service-tier (admin)
# (physical) disconnect failing drive, reboot
scripts/health-audit.ps1                            # verify clean
```
