# Symptom Guide: What windows-ops Helps With

Each symptom this skill handles, with where its real signal lives and the trap that usually misleads the diagnosis. Use it to pick the rung of the Diagnostic Ladder to start on.

## Helps with

Slow boot on a Windows machine that used to be fast — bloat accumulation across the five startup mechanisms (registry Run keys, services, scheduled tasks, startup folders, group policy). The same machine still boots fast once those are inventoried and trimmed.

Failing drives that nobody's spotted yet. The signal lives in System log Events `7` / `52` / `153` / `154` (disk bad block, paging error, retry, hardware error) and `storahci` Event `129` ("Reset to device, \Device\RaidPortN, was issued"). Healthy drives produce zero of these — hundreds in a month means active failure even when SMART still claims "Healthy."

Crashes with no obvious cause. Event 41 (Kernel-Power) carries the BugCheck code at `Properties[0]` and four parameters at `Properties[1-4]`. A `0xEF` (CRITICAL_PROCESS_DIED), `0xD1` (DRIVER_IRQL), `0x124` (WHEA uncorrectable), or `0x0` (no bugcheck recorded → hard power loss) each implies a completely different fix.

"My PC is slow" diagnosed by chasing the wrong symptom. Task Manager shows what's running NOW; the System log shows what failed at boot, what's been crashing, and what storage events preceded each crash. Always audit before treating.

Unable to disable an HKLM startup entry because the user isn't an Administrator. The `StartupApproved` registry mechanism — what Task Manager's "Disable" button actually does — flips one byte in `HKCU\...\Explorer\StartupApproved\Run` and works without elevation, even for HKLM entries.

BSOD analysis without a dump file. Pagefile too small, or hard power loss skipped the dump-write. `CrashDumpEnabled` registry key + pagefile size + free space on system drive determine whether the next crash gets diagnosed at all.

Pre-crash timeline correlation. The events in the 10 minutes BEFORE Event 41 are where the story is. `storahci` resets before a crash → storage failure cascade. `nvlddmkm` / `igdkmd64` warnings before crash → GPU driver hang. WHEA events before crash → hardware fault.

Identifying which physical drive is failing when the symptom is "Disk 1" or "\Device\Harddisk1" in an event message. Maps physical disk number ↔ drive letter ↔ controller port ↔ model + firmware, so the user knows which SATA cable to unplug.

Adobe Creative Cloud / Docker Desktop / Slack / Electron app bloat eating boot time. Each ships with multiple startup entries (registry + services + scheduled tasks) that all need disabling to fully stop the auto-launch.

"Is it safe to physically disconnect drive X?" — finding every system mechanism that references a drive letter before pulling the cable. Pagefile location, Windows Search index, scheduled tasks, services, user-profile junctions / symlinks, startup folder shortcuts, registry Run keys, and volume mount points. The wrong answer destroys uptime; the right answer is a one-line verdict.

Cloning data off a failing drive without finishing it off. `robocopy /R:0 /W:0` (no retries) avoids the "every retry on a bad sector kills the drive faster" trap. For severely damaged drives, `ddrescue` with a resumable map file is the next tier. NEVER `chkdsk /f` a failing drive — repair operations write to bad sectors and accelerate failure.

Recovery from no-boot scenarios — boot configuration data (BCD) repair via `bootrec`, UEFI bootloader rebuild via `bcdboot`, Safe Mode access from a failing system, System Restore from Windows RE, and the boot-sequence triage layers (POST → boot device → boot driver → service load → shell).

Remote Windows diagnostics across the network. PowerShell remoting via WS-Man (the default WinRM transport) or SSH (modern alternative on Win10 1809+). Authentication for in-domain (Kerberos), workgroup (NTLM via `TrustedHosts`), and cross-OS (SSH key) scenarios. The double-hop problem and CredSSP. Running this skill's diagnostic scripts against a remote box by staging the skill folder via `Copy-Item -ToSession`.

Unexplained UAC prompts attributed to their caller. A declined elevation still executes the requesting binary unelevated, so Prefetch run times (PECmd), BAM last-execution FILETIMEs, the npx `_npx` cache, and Security 4688 (if auditing is on) identify exactly what asked for admin and when — see `references/uac-attribution.md` for the playbook and the one-elevated-pass forensic ladder.

Boot duration measurement and slow-startup-component identification. The `Microsoft-Windows-Diagnostics-Performance/Operational` log (admin-only) records per-boot timing — `BootMainPathTime`, `BootPostBootTime`, total, and degradation flag — plus calls out specific apps, drivers, or services that exceeded the system's fast-boot threshold. Without admin, kernel-event fallback gives coarser but still useful timing.

A machine that is hot, loud, or out of commit with no boot-time explanation. The expensive case is a **hung process whose parent is perfectly healthy** — it keeps its supervisor, so every "orphaned process" check reports nothing while it burns a core indefinitely. Measured here 2026-08-30: an orphan scan found 3 processes / 1.16 GB while six live-parented spinners held five cores across 43.8 hours. Rate-sampling finds them; snapshots and lineage never will — see [Runaway Process Triage](../SKILL.md#runaway-process-triage).
