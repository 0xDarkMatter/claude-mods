# Symptom Guide: What mac-ops Helps With

Each symptom this skill handles, with where its real signal lives and the trap that usually misleads the diagnosis. Use it to pick the rung of the Diagnostic Ladder to start on.

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
