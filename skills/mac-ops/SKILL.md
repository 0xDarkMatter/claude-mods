---
name: mac-ops
description: "Comprehensive macOS workstation operations — diagnose kernel panics, identify failing drives, audit launchd startup items, decode wake reasons, triage TCC permission denials, manage APFS snapshots, recover from no-boot. Use for: Mac is slow, slow bootup, won't boot, kernel panic, kernel_task hot, mds_stores CPU, photoanalysisd, cloudd, login loop, gray screen, sleep wake failure, drive failing, IO errors, APFS snapshots eating space, Time Machine local snapshots, Spotlight indexing, launchd, LaunchAgent, LaunchDaemon, login items, TCC permissions, Full Disk Access, Screen Recording denied, Gatekeeper, quarantine, com.apple.quarantine, app is damaged, helper tool, /Library/PrivilegedHelperTools, pmset, wake reasons, dark wake, sysdiagnose, panic.ips, DiagnosticReports, configuration profile, MDM profile, remote diagnostics over SSH."
license: MIT
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
  related-skills: windows-ops, net-ops, debug-ops, perf-ops
---

# mac-ops

> Verified as of 2026-07 — content assumes macOS 13 (Ventura) and later (`.ips` panic format on macOS 12+, universal SSH on macOS 13+).

## Helps with

Slow Mac that used to be fast — bloat accumulation across the four startup mechanisms (Login Items, `~/Library/LaunchAgents`, `/Library/LaunchAgents`, `/Library/LaunchDaemons`). The same machine still boots fast once those are inventoried and trimmed.

Failing drives that nobody's spotted yet. macOS doesn't shout the way Windows does — IO errors live in `log show --predicate 'subsystem == "com.apple.iokit"'` and APFS surfaces them via `AppleAPFSContainerScheme` / `AppleNVMe*` provider messages. Healthy SSDs produce zero of these per month; dozens means active failure even when "About This Mac → Storage" still shows green.

Kernel panics with no obvious cause. The `.panic` / `.ips` files in `/Library/Logs/DiagnosticReports/` carry the panic string, kernel call stack, and (critically) the loaded kext list. A panic mentioning a third-party kext (`com.eltima.ProductX`, `com.paragon.NTFS`, anti-virus drivers) tells a completely different story than a panic in core Apple code (`AppleIntelKBL Graphics`, `IOPlatformPluginUtil`).

"My Mac is slow" diagnosed by chasing the wrong symptom. Activity Monitor shows what's running NOW; `log show` shows what failed at boot, what's been panicking, and what storage / power events preceded each freeze. Always audit before treating.

Apps that "don't work right" but aren't crashing — usually a **TCC** (Transparency, Consent, Control) denial nobody explicitly clicked No to. Screen Recording, Accessibility, Full Disk Access, Camera, Microphone, Contacts, Calendars, Reminders, Photos, Automation — each has its own permission grant. Reading the TCC databases tells you exactly what's been denied and when.

"Macintosh HD is full but I deleted everything" — APFS local Time Machine snapshots plus purgeable space breakdowns. `tmutil listlocalsnapshots /` and `diskutil apfs list` reveal the actual space accounting that Finder hides.

Mac waking up at 3am for no apparent reason. `pmset -g log` records every wake with a reason string (`UserActivity`, `BT.HID`, `EHC0`, `RTC`, `Maintenance`). The pattern across a week tells you whether it's the keyboard, a Bluetooth peer, a kext, or scheduled maintenance.

`mds_stores` / `mdworker_shared` / `photoanalysisd` / `cloudd` / `bird` chewing CPU. Each has a specific cause (Spotlight reindex on a new volume, Photos analyzing faces, iCloud Drive metadata sync) and a specific remedy (per-volume mdutil control, throttling, or waiting it out informedly).

Login loops, gray screen at boot, "kernel" hangs in `loginwindow`. The boot-sequence layers (EFI → bootloader → kernel → launchd → loginwindow → WindowServer → shell) each fail differently; this skill packages the recoveryOS / single-user / verbose-boot patterns.

"Is it safe to eject this disk?" — `lsof +D /Volumes/X`, `mdutil -s`, Time Machine target check, Photos library location, helper-tool security-scoped bookmarks. The wrong answer corrupts the volume; the right answer is a one-line verdict.

Cloning data off a failing drive without finishing it off. `ditto` with `--rsrc` for HFS+ metadata, `rsync --partial --inplace --no-whole-file --append-verify` for resumable transfers. NEVER `fsck_apfs -y` a failing drive — verify-only first (`fsck_apfs -n`), and prefer reading from an APFS snapshot.

Remote macOS diagnostics across the network — SSH (universal on macOS 13+), `kickstart` to enable ARD without a UI, staging the skill folder via `scp -r`.

Apple Silicon vs Intel reality — most diagnostic surface is identical. Where it isn't (Secure Enclave vs T2, panic provenance, boot recovery modes), the differences are flagged explicitly.

## The Universal Insight

**macOS tells you what's wrong if you ask the right log in the right way.** Most users (and most tutorials) reach for Activity Monitor or "About This Mac". The actual diagnostic signal lives in `log show` (the unified logging system), in `/Library/Logs/DiagnosticReports/`, in `pmset -g log`, in the TCC databases, and in `launchctl print`. This skill packages the queries that turn noise into a verdict.

The most common diagnostic failure: treating symptoms in isolation. "Slow boot" → disable login items. "Kernel panic" → reinstall macOS. "Random freezes" → reset SMC/NVRAM. These are reasonable last resorts, but the data to identify the *actual* cause is sitting in the unified log untouched. Always audit before treating.

## The Diagnostic Ladder

Walk down the layers in order. Each rung has a binary outcome:

```
1. Hardware health     — pmset, SMC errors, thermal events, Secure Enclave
2. Storage health      — APFS state, IO errors, snapshot bloat
3. Panic record        — DiagnosticReports/*.{panic,ips} + kext provenance
4. Pre-panic timeline  — log show last 10 minutes before each panic
5. Startup inventory   — Login Items + LaunchAgents + LaunchDaemons + profiles
6. Resource pressure   — top CPU/mem, mds_stores, photoanalysisd, cloudd
7. Permissions / TCC   — what app is denied what (the macOS-unique rung)
8. Verdict             — what's failing, what to do
```

The most interesting failures cluster at rungs 2 (storage), 5 (startup bloat), and 7 (TCC denials). The least interesting (but most-treated) is rung 6.

## Workflow

### 1. Run the comprehensive audit

```bash
scripts/health-audit.sh
```

Produces a verdict block: hardware events, storage health per volume, recent panics, top resource consumers, startup inventory, TCC denials. Scan for `[FAIL]` markers — that's where to drill.

### 2. Drill into the failing layer

| Symptom | Script |
|---|---|
| Storage errors flagged | `scripts/disk-health.sh -v /Volumes/X` (or `-d disk2`) — focused per-volume deep dive: APFS state, IO errors, snapshot bloat, verdict |
| Recent panic | `scripts/panic-triage.sh` (latest by default) or `-f /Library/Logs/DiagnosticReports/Kernel_*.panic` — kext + pre-panic timeline |
| "Is it safe to eject volume X?" | `scripts/drive-dependencies.sh -v /Volumes/X` — open files, Spotlight index, TM target, Photos lib, helper-tool bookmarks |
| "Why is boot taking so long?" | `scripts/boot-perf.sh` — per-boot durations from log show, with slow-component flags |
| App can't see screen/mic/files | `scripts/tcc-audit.sh -a <bundle-id-or-name>` — what TCC has granted, what's been denied recently |
| Mac waking at night | `scripts/wake-reasons.sh` — pmset log breakdown by reason class |
| Spotlight broken / mds CPU spike | `scripts/spotlight-status.sh` — index state per volume, common fixes |
| Storage "full" but disk usage doesn't add up | `scripts/storage-pressure.sh` — APFS snapshots, local Time Machine, purgeable bytes |
| Kernel panic blames a kext / loaded kext audit | `scripts/kext-audit.sh` — third-party kexts + system extensions + SIP/security policy state |
| Firewall behavior / VPN tunnel inventory | `scripts/firewall-audit.sh` — ALF + pf + Network Extension content filters + utun inventory |
| Network preferences across location profiles | `scripts/network-locations.sh` — DNS / proxy / search domains per location, service order |

### 3. Apply the minimum reversible fix

| Action | Script |
|---|---|
| Disable startup item by name | `scripts/safe-disable-startup.sh -n <pattern>` — works across Login Items + LaunchAgents (no sudo for user-scope) |
| List current state of all startup entries | `scripts/safe-disable-startup.sh --list` |
| Re-enable previously disabled | `scripts/safe-disable-startup.sh -n <pattern> --enable` |
| Disable system-scope daemon (admin) | `sudo launchctl disable system/<label>` then `sudo launchctl bootout system/<label>` |
| Reset TCC for a specific service+bundle | `tccutil reset <Service> <bundle-id>` (per-service, not global) |
| Safe clone from failing drive | `scripts/recover-clone.sh -s <source> -d <destination>` — rsync `--partial --inplace --no-whole-file` |

All disables are reversible — Login Items via `osascript` System Events, LaunchAgents via `launchctl disable`. The inverse re-enables.

## Storage Health & Failure Detection

The highest-yield audit. Failing drives cause slow boots (kernel waits on probe timeouts), instability (IO retries cascade into kernel hangs), and panics (paging failures kill `WindowServer`). Three independent data sources to cross-reference:

### IO error events

```bash
log show --last 30d --style compact \
    --predicate 'subsystem == "com.apple.iokit" AND (eventMessage CONTAINS "I/O error" OR eventMessage CONTAINS "media error")' \
    2>/dev/null | head -30
```

Healthy drives produce zero of these per month. Dozens = active failure regardless of what "About This Mac → Storage" claims.

### APFS health

```bash
diskutil apfs list
diskutil apfs verifyVolume /        # READ-ONLY — does not write
```

Look for `Verify failed` per-volume, container free-space mismatches, or snapshot trees growing without bound.

### SMART status (via vendor / smartmontools)

macOS's built-in SMART status (`diskutil info /dev/diskN`) reports only `Verified` or `Failing`. For real attributes, install `smartmontools` (`brew install smartmontools`) and use `smartctl -a /dev/diskN`. NVMe drives often return blank — fall back to vendor tools or the per-vendor utilities.

### Disk → volume mapping

```bash
diskutil list
diskutil info disk2s1
```

Cross-reference with `df -h` for mount point.

## Boot Performance & Startup Management

macOS has **four primary startup mechanisms**, each requiring different tooling. System Settings only shows one of them (Login Items). Full inventory in `references/startup-mechanisms.md`.

| Mechanism | Where | How to inspect | How to disable |
|---|---|---|---|
| Login Items | System Settings → General → Login Items | `osascript` System Events | `osascript` (no sudo) |
| User LaunchAgents | `~/Library/LaunchAgents/*.plist` | `launchctl print gui/$UID` | `launchctl disable gui/$UID/<label>` |
| System LaunchAgents (per-user) | `/Library/LaunchAgents/*.plist` | `launchctl print gui/$UID` | `launchctl disable gui/$UID/<label>` (no sudo for current user) |
| System LaunchDaemons | `/Library/LaunchDaemons/*.plist` | `sudo launchctl print system` | `sudo launchctl disable system/<label>` |
| (Legacy) LoginHook | `com.apple.loginwindow` LoginHook key | `sudo defaults read com.apple.loginwindow LoginHook` | `sudo defaults delete com.apple.loginwindow LoginHook` |

### `launchctl disable` vs `bootout`

| Command | Effect |
|---|---|
| `launchctl disable <domain>/<label>` | Persistently disabled across reboots. **Reversible** with `enable`. |
| `launchctl bootout <domain>/<label>` | Unloads the running service NOW. Comes back on next reboot if not also `disable`d. |
| `launchctl unload <plist>` | Legacy form. Avoid in new scripts. |

The right pair for "kill this daemon permanently": `disable` then `bootout`. The script `scripts/safe-disable-startup.sh` does both.

### Boot duration measurement

macOS records boot timing in the unified log. Approximate via:

```bash
log show --last 1h --style compact \
    --predicate 'eventMessage CONTAINS "BOOT_TIME" OR eventMessage CONTAINS "loginwindow"' \
    | head -50
```

Healthy Apple Silicon Mac: 10-20s to login screen. Intel Mac with spinning disk (vintage 2015 Mini): 25-45s. Failing storage: 60+s with stalls.

## Panic Analysis & Diagnostic Reports

### Where panics live

```
/Library/Logs/DiagnosticReports/*.panic          (legacy Intel + early Apple Silicon)
/Library/Logs/DiagnosticReports/*.ips            (modern format, all panics on macOS 12+)
~/Library/Logs/DiagnosticReports/                (per-user crashes, not panics)
```

`.ips` files are JSON. The `.panic` files are plain text but follow a strict structure.

### Anatomy of a panic report

```
panic(cpu N caller 0x...): "Sleep wake failure in EFI"
Loaded kexts:
  com.apple.driver.AppleEFIRuntime           ...
  com.eltima.ProductX                        2.1.7    <— third-party suspect
  ...
```

The **kext list** is the most actionable signal. A panic that loaded only Apple kexts is harder to fix than one with a clear third-party suspect — kext-extraction-and-removal is the first move.

### Common panic strings (full catalog in `references/panic-codes.md`)

| String fragment | Likely cause |
|---|---|
| "Sleep wake failure" | Driver hung during S3/S4 transition (often USB, Bluetooth, GPU) |
| "Unable to find driver" | Boot-time kext load failure — likely after macOS update |
| "Unresponsive bootstrap subsystem" | `launchd` deadlock — usually third-party LaunchDaemon |
| "WindowServer panic" | GPU driver or display kext fault |
| "double_fault" / "page_fault" | Kernel-mode memory corruption — kext bug or RAM fault |
| "panic_kthread" | Kernel watchdog timeout — driver in infinite loop |

### Pre-panic timeline

The panic record alone rarely tells you the cause. The **events in the 10 minutes before** are where the story is:

```bash
scripts/panic-triage.sh -t '2026-05-15 03:14:22' -m 10
```

Look for:
- Disk arbitration errors before panic → storage failure cascade
- `kernel` warnings naming a third-party kext before panic → driver hang
- `powerd` / `assertion` messages before sleep panic → pmset assertion held by misbehaving app

## TCC (Privacy Permissions) Audit

A macOS-unique diagnostic layer. The TCC databases at:

```
/Library/Application Support/com.apple.TCC/TCC.db     (system, requires sudo)
~/Library/Application Support/com.apple.TCC/TCC.db    (per-user)
```

…store every "Allow / Deny" grant ever made. Reading them tells you exactly which app has Screen Recording, Camera, Microphone, Full Disk Access, Accessibility, Automation, etc. — and which apps have been **denied** recently (the most common "this app doesn't work" cause).

Full schema and reset procedures in `references/tcc-mechanics.md`. The `scripts/tcc-audit.sh` script wraps the common queries.

## Common Failure Modes

| Symptom | First check | Common cause |
|---|---|---|
| Slow boot, used to be fast | `startup-audit.sh` | Login Item / LaunchAgent bloat (Adobe CC, Docker, Setapp) |
| Slow boot, getting worse | `disk-health.sh` | Failing SSD — APFS retries inflating boot time |
| Random freezes + hard restart | `disk-health.sh` + `panic-triage.sh` | IO errors cascading into kernel hang |
| Kernel panic on wake | `panic-triage.sh` (look for "Sleep wake failure") | Driver power-state bug (often USB, GPU, Bluetooth) |
| App can't access screen/mic | `tcc-audit.sh -a <app>` | TCC denial, often from a recent system update |
| "Macintosh HD almost full" | `storage-pressure.sh` | Local Time Machine snapshots + purgeable cache |
| Mac wakes at 3am | `wake-reasons.sh` | Scheduled maintenance, BT keyboard tap, or kext bug |
| `mds_stores` CPU 100% | `spotlight-status.sh` | Reindex on volume with no on-disk index store |
| Login loop / gray screen | recoveryOS + safe boot + this skill's recovery docs | Bad LaunchAgent, corrupt Login Items, kext panic at boot |

## Recovery Patterns

### Failing-drive data recovery

**Never `fsck_apfs -y` a failing drive** — `-y` answers Yes to repairs, which writes back. Use `fsck_apfs -n` (verify-only) first. Image first, repair the image second.

```bash
# Safe clone with no retries (skips bad sectors fast)
rsync -avh --partial --inplace --no-whole-file --append-verify \
    /Volumes/Failing/important/ /Volumes/Rescue/important/
```

For bit-level recovery, install `gddrescue` via Homebrew and use a map file so the operation is resumable. Documented in `references/recovery-patterns.md`.

### Physically removing a failing drive

If a drive is causing boot stalls or panics:

1. Identify via `disk-health.sh`
2. Verify nothing critical points at it (`drive-dependencies.sh -v /Volumes/X`)
3. `diskutil unmount /Volumes/X` (or `diskutil eject /dev/diskN` for the whole device)
4. Physically disconnect / power down before remount attempts

## Voice & Output Style

Output follows the claude-mods diagnostic convention:

- `[PASS]` / `[FAIL]` / `[WARN]` / `[INFO]` prefixes for scan rows
- Verdict block at the bottom with specific findings + recommended actions
- Volume identifications include disk identifier, mount point, APFS role
- Panic references include UTC timestamp, panic string, primary suspect kext
- Panel rendering via `skills/_lib/term.sh` when a TTY is present; raw text otherwise
- `--json` emits NDJSON for piping; `--redact` masks private addrs / hostnames / serial numbers

## What This Skill Doesn't Cover

- **Network diagnostics** → use `net-ops`
- **Windows-side workstation issues** → use `windows-ops`
- **Specific application performance profiling** → use `perf-ops`
- **Source-code-level debugging** → use `debug-ops`
- **iOS / iPadOS device issues** — different platform
- **MDM authoring** (creating configuration profiles) — out of scope; we read them, not author them

## Cross-References

| When | Use |
|---|---|
| Triaging a remote Mac | `net-ops/ssh-bootstrap.sh` to land, then this skill's scripts |
| Panic blames a network kext | Combine with `net-ops` for VPN/DNS interactions |
| Same pattern on multiple Macs | Run `health-audit.sh --json` on each, diff outputs |
| Suspect Windows + Mac in same household | `windows-ops` + `mac-ops`, same conventions |

## References

- `references/storage-events.md` — IO error patterns in unified log, APFS-specific event vocabulary, disk arbitration messages. Load when investigating volume errors or correlating IO failures to a specific device.

- `references/panic-codes.md` — Common kernel panic strings, kext-extraction patterns, Apple Silicon vs Intel panic format differences. Load when decoding a non-trivial `.panic`/`.ips` file or matching a symptom to a likely cause.

- `references/startup-mechanisms.md` — Deep dive on Login Items, LaunchAgents (user + system), LaunchDaemons, legacy LoginHook, configuration profile login items. Load when doing a full startup audit or hunting vendor-installed auto-launch hooks.

- `references/recovery-patterns.md` — Failing-drive recovery (rsync, gddrescue), APFS snapshot rollback, target disk mode, recoveryOS, single-user mode on Apple Silicon vs Intel. Load when responding to "my drive is dying" or any destructive operation.

- `references/remote-diagnostics.md` — SSH staging pattern (`scp -r mac-ops/ remote:`), `kickstart` for enabling ARD, sudo over SSH considerations. Load when troubleshooting "my parents' Mac across town".

- `references/tcc-mechanics.md` — How TCC works under the hood. Both TCC.db locations, "service" string catalog (kTCCServiceScreenCapture, kTCCServiceAccessibility, etc.), grant types, when to use `tccutil reset` vs editing the DB, SIP interaction. Load when an app silently fails to access screen / mic / files.

- `references/launchd-deep-dive.md` — launchd plist semantics, `RunAtLoad` vs `KeepAlive`, `ThrottleInterval`, why daemons fail to load, `disable` vs `bootout` vs `unload`, domain targets (system, user, gui), and Apple Silicon specifics (system extensions replacing kexts).

## Worked example

A user reports "my Mac wakes itself at 3am and is slow during the day." Running `scripts/health-audit.sh` produces a panel that follows the [Terminal Panel Design System](../../docs/TERMINAL-DESIGN.md):

```
╭── 🩺 mac-ops · health-audit ───────────────────────────────────── macks-mbp ───●
│
├── 3 volumes · 1 panic · 4 wakes/24h · 12 startup items
│
├── failing (4)
│   ├── [panic] 2026-05-14 03:14    Sleep wake failure (com.kext.example.AcmeUSB)
│   ├── [wake]  3 wakes from BT.HID    Bluetooth keyboard activity at night
│   ├── [tcc]   Slack denied Screen Recording   (granted previously, lost after update)
│   └── [start] 12 login items, 3 disabled, 2 unsigned
│   │   ▲ remove AcmeUSB kext; pair BT keyboard to phone for night; re-grant Slack TCC
│
├── warn (2) · pass (9) · info (3)
│
╰── R refresh · D drill · ? help ─────────────────── ⬤ panic  • bt-wake  • tcc ───●
```

Three commands solve it: `panic-triage.sh` decodes the panic; `wake-reasons.sh` shows BT.HID is the dominant wake class; `tcc-audit.sh -a slack` confirms denied. The data was always there — this skill just asks for it correctly *and renders it like a proper instrument*.

### Legacy / non-panel mode

All scripts accept `--json` for NDJSON output (parses with `jq`) and `--redact` for opsec-clean diagnostic dumps. When stdout is not a TTY, panel chrome auto-disables and plain text emits.

Full command sequence for the example:

```bash
scripts/health-audit.sh                            # diagnose
scripts/panic-triage.sh                            # decode most recent panic
scripts/wake-reasons.sh --since 7d                 # weekly wake pattern
scripts/tcc-audit.sh -a Slack                      # check denied permissions
scripts/safe-disable-startup.sh --list             # audit startup state
scripts/safe-disable-startup.sh -n 'Adobe*'        # cull bloat
sudo launchctl disable system/com.kext.example.AcmeUSB.daemon
# (then reboot to confirm panic doesn't return)
scripts/health-audit.sh                            # verify clean
```
