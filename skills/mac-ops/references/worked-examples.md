# Worked Examples

Three end-to-end diagnostic scenarios run through mac-ops. Each shows the symptom, the script sequence, the actual signal in the output, and the fix. Treat these as patterns to recognize — they cover the most common Mac complaints in 2026.

## Example 1: "My Mac is slow and feels hot"

### Symptom

User reports: "Mac is sluggish. Fans run constantly even when I'm not doing anything. Battery drains faster than it used to."

### Diagnostic sequence

```bash
scripts/health-audit.sh --days 7
```

Expected verdict pattern:

```
=== 5. RESOURCE PRESSURE (snapshot) ===
  Top 5 by CPU%:
     63.2% [  582] mds_stores
     21.4% [  328] mds
     18.1% [    367] WindowServer
     ...
[WARN] mds_stores CPU :: 63.2% — sustained spike?

=== 6. WAKE PATTERN (last 24h) ===
[WARN] Wakes in pmset log (full history) :: 1247 — drill with wake-reasons.sh
```

Two signals: heavy Spotlight + lots of wakes. Drill:

```bash
scripts/spotlight-status.sh
scripts/wake-reasons.sh --since 7d
```

Spotlight typically shows one of three causes:
- **Heavy ongoing reindex** (new external volume mounted recently)
- **Indexing a path it shouldn't** (large dev folders, node_modules, .git)
- **Corrupt index** (mds_stores spinning on the same file forever)

For the third case, the fix is brutal but effective:

```bash
sudo mdutil -E /                  # nuke + rebuild index
```

Plan for 1-4 hours of high mds_stores CPU after this; it's the rebuild. After that, idle CPU should return.

Wake-reasons typically shows:

```
rtc scheduled   |  115 |  11%  (rtc/Maintenance)    ← Power Nap
wifi/bluetooth  |  111 |  11%  (wlan/)               ← Wi-Fi proximity wake
push-svc wake   |   76 |   7%  (rtc/SleepService)   ← push notification maintenance
```

The fix is in System Settings → Battery → Options:
- Power Nap: Off (especially on battery)
- Wake for network access: Off

### Why this presents as "slow + hot"

When a Mac wakes for "maintenance" hundreds of times overnight, the SoC spends fractional CPU keeping things warm. Daytime, the user perceives the heat lingering. Over a week, battery cycle count creeps up.

---

## Example 2: "I can't share my screen on Zoom anymore"

### Symptom

User reports: "Zoom worked yesterday. Today the screen-share button just doesn't do anything. No prompt appears."

### Diagnostic sequence

This is the textbook TCC denial. Bypassed via:

```bash
scripts/tcc-audit.sh -a zoom --denied
```

Expected output:

```
=== 2. PERMISSION GRANTS ===
  service                      | client                                              | auth | last modified
  -----------------------------|----------------------------------------------------|------|------------------------
  kTCCServiceScreenCapture     | us.zoom.xos                                        | DENY | 2026-05-15 04:12:00
```

The DENY row tells the whole story: Zoom's Screen Recording permission was revoked. Common causes:
- macOS update reset the grant
- User clicked "Don't Allow" on a prompt
- An MDM profile revoked it

### Fix

```bash
tccutil reset ScreenCapture us.zoom.xos
```

Then re-open Zoom and attempt screen share — macOS prompts; user approves; permission persists.

If the user is on a managed Mac and tccutil shows the grant has `auth_reason = 6` (MDM-set), they need to contact IT to amend the configuration profile.

### Cross-verification

```bash
scripts/health-audit.sh
```

Rung 7 (TCC) will now show:

```
[WARN] User TCC grants (denied) :: 3 — drill with tcc-audit.sh
```

If that count was elevated before the Zoom fix and dropped after, you've confirmed the same kind of denial pattern.

---

## Example 3: "Macintosh HD is full but I deleted everything"

### Symptom

User reports: "About This Mac says I have 4 GB free out of 500 GB. I just emptied the Trash and the number didn't move."

### Diagnostic sequence

```bash
scripts/storage-pressure.sh -v /
```

Expected output:

```
=== 1. df vs APFS reality ===
  /dev/disk3s1s1   460Gi   456Gi   4.0Gi    99%   ...    /

  diskutil info (APFS-aware):
     Container Free Space:      103.0 GB    ← significantly more than df shows
     APFS Snapshots are defined upon this APFS Volume.

=== 2. APFS SNAPSHOTS ===
[WARN] Local Time Machine snapshots :: 42 — purgeable space tied up

=== 4. CACHE / TEMPORARY DIRECTORIES ===
  User caches:
    /Users/.../Library/Caches = 87 GB         ← Docker, browser caches, Spotify, etc.
```

Two reclaim paths:

**Path A: Cull local Time Machine snapshots**

```bash
tmutil thinlocalsnapshots /          # macOS chooses which to delete
# or:
tmutil deletelocalsnapshots <name>   # specific snapshot
```

42 snapshots can easily hold 50+ GB. macOS auto-purges these under pressure, but the user perceives "disk full" before the purge fires.

**Path B: Clear user caches**

```bash
rm -rf ~/Library/Caches/com.docker.docker     # Docker
rm -rf ~/Library/Caches/com.spotify.client    # Spotify
brew cleanup -s                                # Homebrew
docker system prune -af --volumes              # Docker images + volumes
```

After either path, re-run `storage-pressure.sh`. Container Free Space and df should converge.

### Why "About This Mac → Storage" lies

That UI counts purgeable space as "Other" and rounds. APFS snapshots are user-deletable in principle but macOS won't expose them through the UI. `tmutil` and `diskutil apfs list` are the truth.

---

## Worked example

A user reports "my Mac wakes itself at 3am and is slow during the day." Running `scripts/health-audit.sh` produces a panel that follows the [Terminal Panel Design System](../../../docs/TERMINAL-DESIGN.md):

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

## General pattern: walking the ladder

For any "my Mac is doing X weird" complaint:

```bash
# 1. Start with the orchestrator
scripts/health-audit.sh

# 2. The verdict block's "Next:" line points at the right drilldown.
#    Run that. If multiple rungs failed, address rung 2-3 (storage,
#    panics) BEFORE rung 6-7 (resource, TCC) since they're root-cause.

# 3. Apply the minimum reversible fix.
#    Disable startup items via safe-disable-startup.sh, not by deleting plists.
#    Reset TCC grants via tccutil, not by editing TCC.db.
#    Cull snapshots via tmutil, not by APFS snapshot deletion.

# 4. Re-run health-audit. Confirm the verdict cleaned up.
```

The discipline: **verify before treating**. The data is always sitting in `log show`, `tmutil`, `tccutil`, `pmset -g log`. mac-ops just asks for it correctly.

## Cross-references

- The main skill flow: `SKILL.md`
- For mac-ops vs windows-ops decisions: `mac-vs-windows-ops.md`
- For each script's standalone use: that script's `--help`
