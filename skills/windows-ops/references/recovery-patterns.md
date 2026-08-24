# Windows Recovery Patterns

Load this when responding to "my drive is dying, what do I do RIGHT NOW", filesystem-level corruption, boot configuration damage, or system file integrity issues. These are the procedures that have to be right the first time — getting them wrong destroys data.

## Contents

1. [The cardinal rules](#the-cardinal-rules) — what NEVER to do
2. [Failing-drive data recovery](#failing-drive-data-recovery) — robocopy, ddrescue, vendor tools
3. [Filesystem repair](#filesystem-repair) — chkdsk semantics, when to use what flag
4. [System file integrity](#system-file-integrity) — sfc, DISM
5. [Boot configuration repair](#boot-configuration-repair) — BCD, MBR, bootrec
6. [Pagefile management](#pagefile-management) — moving pagefile off a failing drive
7. [Drive removal procedures](#drive-removal-procedures) — offline, physically disconnect, BIOS-disable
8. [Recovery from no-boot](#recovery-from-no-boot) — Windows RE, Safe Mode, System Restore

## The cardinal rules

These never bend:

1. **Image first, repair second.** When a drive is failing, your priority is getting data OFF it before doing anything that writes TO it. Repair operations write to bad sectors; that finishes a marginal drive faster than any other action.

2. **Never `chkdsk /f` a failing drive.** The `/f` flag writes fixes back to disk. If the drive is throwing hardware errors, every write is potentially the one that kills it. Read-only chkdsk (`chkdsk` with no flags, or explicitly `chkdsk /scan /forceofflinefix`) is OK; anything that writes is not.

3. **Never run `format` or `convert` on a drive you want data from.** Obvious but it gets done in panic.

4. **Don't trust SMART "Healthy"** when event logs are screaming. Windows reports SMART status based on a small handful of attributes; meanwhile the System log can have thousands of Event 7 / 154 hardware errors. The events are the truth.

5. **Don't pound on a failing drive with retries.** Robocopy default is `/R:1000000`. Use `/R:0`. Every retry on a bad sector causes the drive's internal retry-and-relocate logic to run, which stresses both the failing sector and the spare-sector pool.

## Failing-drive data recovery

### Tier 1: Healthy-side clone with robocopy `/R:0`

When the drive is still mostly readable and you can mount it:

```powershell
robocopy "Y:\important-data" "Z:\rescue\important-data" `
    /MIR /XJ /COPY:DAT /DCOPY:T `
    /R:0 /W:0 `
    /MT:8 `
    /V /BYTES /NP `
    /LOG:"$env:TEMP\clone.log" /TEE
```

Flag breakdown:

| Flag | Effect |
|------|--------|
| `/MIR` | Mirror — recursive copy AND delete files at destination that don't exist at source. Use `/E` instead if destination has other content to preserve. |
| `/XJ` | Skip junction points. Prevents infinite recursion if a junction loops back. |
| `/COPY:DAT` | Copy Data, Attributes, Timestamps. Skip ACL/Owner (faster, usually unwanted on a recovery target anyway). |
| `/DCOPY:T` | Also copy directory timestamps. |
| `/R:0 /W:0` | **Zero retries.** Critical — skip bad sectors fast instead of retrying. |
| `/MT:8` | 8 threads (default; explicit for clarity). |
| `/V` | Verbose log includes which files were skipped — needed for the failed-files list. |
| `/BYTES /NP` | Cleaner log output for parsing. |
| `/LOG:path /TEE` | Log to file + console. |

Robocopy exits with a bitmask (>=8 means errors). The skill's `scripts/copy-tree.ps1` wraps this with proper exit-code translation and failed-files extraction.

### Tier 2: Image-level recovery with ddrescue

When the drive has many bad sectors or the filesystem itself is unreliable:

`ddrescue` (GNU ddrescue) reads the raw block device, skips errors, comes back later to retry just the failed regions. Two-pass recovery with a map file makes it resumable across crashes/cable yanks.

Install via WSL:
```bash
wsl sudo apt install gddrescue
```

Or boot a live Linux USB.

First pass — read everything that's easy:
```bash
ddrescue -d -r0 /dev/sdX recovery.img mapfile
```
- `-d` direct (skip OS buffering)
- `-r0` zero retries on first pass

Second pass — retry the failed regions, this time aggressively:
```bash
ddrescue -d -r3 -R /dev/sdX recovery.img mapfile
```
- `-r3` three retries on remaining bad blocks
- `-R` reverse direction (sometimes recovers what forward couldn't)

The skill wraps both passes in `scripts/rescue-image.ps1`, which adds the parts
you only discover the hard way:

```powershell
scripts/rescue-image.ps1 -ListDevices                              # map devices FIRST
scripts/rescue-image.ps1 -Device /dev/sdX1 -Image R:\rescue.img    # first pass
scripts/rescue-image.ps1 -Device /dev/sdX1 -Image R:\rescue.img -Pass retry
```

**Why a supervisor is not optional under Cygwin.** Some hard read errors reach
ddrescue as `EACCES` ("Permission denied") instead of `EIO`, because Windows
returns a misleading error code for the raw device. ddrescue treats that as fatal
and exits — in one measured recovery, about every 9 minutes while otherwise
sustaining 70 MB/s. It is not a permissions fault and elevation does not prevent
it. The mapfile makes relaunching free, so the script simply relaunches until the
pass completes. Left unsupervised, the same run stops after the first few minutes
and looks finished.

**Choosing the environment.** A Linux live USB is the cleanest ddrescue host, but
it costs a power cycle — and a drive that has already failed once may never spin
up again. When the device is currently readable, prefer an in-session route
(Cygwin) over rebooting to a "better" environment you may not get to use.

### Tier 2b: Getting files back out of the image

Windows cannot natively mount a raw *partition* image: `Mount-DiskImage` handles
VHD/VHDX/ISO only, and the usual "append a VHD footer" trick fails because a
partition image has no partition table — Windows presents an uninitialised disk
rather than a volume. Third-party volume mounters work but are another install.

7-Zip reads NTFS as an archive format — read-only, no driver, no mount, nothing
written to the image — and it is usually already present:

```powershell
scripts/extract-image.ps1 -Image R:\rescue.img -Plan                     # what's in there
scripts/extract-image.ps1 -Image R:\rescue.img -Dest R:\out -Include 'Users\*'
scripts/extract-image.ps1 -Image R:\rescue.img -Dest R:\out -Verify      # what didn't make it
```

Run `-Verify` before trusting a resumed extraction. 7-Zip's `-aos` skips files
that already **exist**, not files that are **complete**, so a write interrupted by
a crash or an unmounted destination is treated as done on the next attempt.
`-Verify` catches those by size.

**Expect large files to fail wholesale.** A single unreadable sector fails the
entire file it belongs to, so a small number of unrecovered regions can cost
disproportionately — in one recovery, 30 GB of unread sectors made ~1.3 TB of
large files unextractable while 99.6% of the drive imaged cleanly. If the missing
files matter, that is the argument for a Tier 2 retry pass before discarding the
source drive.

### Credential exports found on recovered media

Password managers export to **plaintext** CSV/XML by design. If a rescue turns up
`*_export.csv` or similar, treat every credential in it as compromised and rotate
it — do not treat deletion as remediation. You cannot prove the bytes are gone:
overwrite-in-place is defeated by SSD wear-levelling, copy-on-write filesystems,
and any snapshot or backup that captured the file. Rotation is the control that
actually works; deletion only limits further exposure.

`extract-image.ps1` excludes common export filenames by default so a bulk
extraction cannot silently re-create them on a new volume.

### Tier 3: Professional data recovery

When the drive has mechanical failure (clicking, not spinning, drive ID lost) — stop touching it. Every power cycle risks more damage. Professional cleanroom recovery (Ontrack, DriveSavers, local equivalents) costs $300-3000 AUD depending on damage, but is the only option for physical-fault drives.

## Filesystem repair

### chkdsk decision tree

| Situation | Command | What it does |
|-----------|---------|--------------|
| **Failing drive — DO NOT RUN** | Don't `chkdsk /f` | Writes to disk; can finish off marginal drive |
| Drive healthy, suspicious files | `chkdsk D:` | Read-only check. Reports problems. No writes. Safe. |
| Drive healthy, repair-OK | `chkdsk D: /f` | Fixes filesystem errors. Locks volume. |
| Drive healthy, also fix bad sectors | `chkdsk D: /r` | Implies `/f` + scans every sector + recovers what it can from bad ones. **Days for large drives.** |
| Drive healthy, faster repair | `chkdsk D: /spotfix` | Fixes targeted issues only. Doesn't need offline volume. |
| System drive, schedule for next boot | `chkdsk C: /f /scan` | Can't lock C: live; schedules check at next boot. |
| Just scan, don't fix | `chkdsk D: /scan` | Online scan, reports only. Won't fix. |

### Filesystem corruption signals

NTFS will throw `Ntfs` Event 55 ("A corruption was discovered in the file system structure on volume X") when it spots metadata issues mid-operation. If you see this:

1. Don't ignore it
2. **First** image the drive (Tier 1 or Tier 2 above)
3. Then run `chkdsk /scan` (read-only) to assess
4. Then decide if repair is safe (depends on hardware state)

### $LogFile / $MFT damage

If chkdsk reports MFT or $LogFile damage, the drive is in a precarious state. Options:

- Clone the drive first (always), then `chkdsk /f` on the clone
- If the original is failing physically: use `ntfsfix` from Linux (lighter touch than Windows chkdsk; doesn't try to recover bad sectors)
- Worst case: image the drive and use `TestDisk` to reconstruct partition tables and `PhotoRec` to extract files by signature

## System file integrity

### When Windows system files are corrupt

Symptoms: blue screens during boot, services failing to start, Windows Update broken, `winver` crashes.

Run in this order:

```powershell
# 1. System File Checker - replaces corrupt protected files from cache
sfc /scannow

# 2. If sfc reports unfixable corruption, repair its own source (component store)
DISM /Online /Cleanup-Image /CheckHealth          # quick check
DISM /Online /Cleanup-Image /ScanHealth           # deeper scan
DISM /Online /Cleanup-Image /RestoreHealth        # actually repair (uses Windows Update)

# 3. Then re-run sfc
sfc /scannow
```

`DISM /RestoreHealth` downloads replacement files from Windows Update, so the machine needs internet and a working WU stack. If WU itself is broken, supply a known-good `install.wim` via `/Source:WIM:D:\sources\install.wim:1`.

### Component store cleanup

Over years the WinSxS component store grows. Reset/cleanup:

```powershell
DISM /Online /Cleanup-Image /StartComponentCleanup           # standard cleanup
DISM /Online /Cleanup-Image /StartComponentCleanup /ResetBase  # plus drops update rollback data (saves more but irreversible)
```

## Boot configuration repair

### When Windows won't boot

Boot to Windows Recovery Environment (Windows RE):
- Three failed boots automatically triggers RE on Win10/11
- Or boot from installation USB → "Repair your computer" → Troubleshoot → Advanced Options → Command Prompt

### BCD (Boot Configuration Data) repair

```cmd
bootrec /fixmbr        :: Repair MBR (legacy BIOS only)
bootrec /fixboot       :: Write new boot sector to system partition
bootrec /scanos        :: Scan for Windows installs
bootrec /rebuildbcd    :: Rebuild BCD store from scratch
```

If `/fixboot` returns "Access denied" (common on UEFI):

```cmd
:: Find the EFI partition and rebuild bootloader
diskpart
list volume
select volume <EFI partition number>     :: Usually ~100 MB, FAT32
assign letter=Z
exit
bcdboot C:\Windows /s Z: /f UEFI         :: Recreate UEFI boot files
```

### Drive enumeration changed → BCD points at wrong disk

Symptom: BSOD `0x7B` (INACCESSIBLE_BOOT_DEVICE) after hardware change. The BCD references the system drive by device path; if SATA ports rearranged or you added an NVMe, the path may be stale.

```cmd
bcdedit /enum                          :: Show current BCD entries
bcdedit /set {default} device boot     :: Reset to logical "boot"
bcdedit /set {default} osdevice boot
```

## Pagefile management

### Moving pagefile off a failing drive

If a failing drive hosts (part of) the pagefile, Windows will continue to read/write to it under memory pressure — accelerating drive failure and risking BSOD `0x50` PAGE_FAULT_IN_NONPAGED_AREA.

```powershell
# Find current pagefile location(s)
Get-CimInstance Win32_PageFileSetting

# Remove pagefile from a specific drive (requires admin + reboot)
$pf = Get-CimInstance Win32_PageFileSetting | Where-Object { $_.Name -like 'Y:*' }
$pf | Remove-CimInstance

# Or relocate: set on a healthy drive first, then remove from failing
$newPf = New-CimInstance -ClassName Win32_PageFileSetting -Property @{
    Name = 'C:\pagefile.sys'
    InitialSize = 0    # 0 = system managed
    MaximumSize = 0
}
```

Changes apply at next reboot. If the failing drive can't be cleanly removed (it's needed at boot for some reason), at minimum reduce its pagefile to 16 MB minimum, 16 MB maximum to limit damage.

### Pagefile sizing for crash dumps

For a complete kernel memory dump on Win11, pagefile on the system drive must be ≥ RAM size (or `DedicatedDumpFile` configured). For minidumps, ≥256 MB is enough. System-managed sizing handles this automatically.

## Drive removal procedures

When you've decided to take a drive offline (failing, replacing, decommissioning), there's a hierarchy from least to most invasive:

### Software-only (drive stays plugged in)

```powershell
# Take drive offline — Windows won't try to use it until next reboot or manual online
diskpart
DISKPART> select disk N
DISKPART> offline disk
DISKPART> exit
```

Useful when:
- Drive will be physically disconnected at next shutdown
- You want to test that nothing depends on it (apps that need it will error out, surfacing dependencies)
- Quick reversibility — `online disk` brings it back

### BIOS-disable (drive stays plugged in but firmware skips it)

Reboot, enter BIOS, find storage configuration, disable the specific SATA port or NVMe slot. Use when:
- Drive is causing boot stalls (Windows-side `offline` doesn't help boot time)
- You don't want to open the case yet
- Reversible without disassembly

### Physical disconnect

The complete solution. SATA: unplug data cable (power cable can stay). NVMe: unscrew the standoff and lift the drive out of the slot. Use when:
- Drive is causing crashes (any contact with it is a risk)
- You're done with it permanently
- Boot performance still bad after BIOS disable (rare but possible)

### Drive destruction (for sensitive data)

Don't trust `format` or even `cipher /w:` on a failing drive — bad sectors may retain readable data. For sensitive data on a drive being decommissioned:

- **HDD**: physical destruction (drill press through platters, or pay a shredding service)
- **SSD**: `cipher /w:Y:\` for a healthy SSD (forces wear-leveling to overwrite); for failing SSDs, physical destruction is the only reliable path

ATA Secure Erase (`hdparm --security-erase` from Linux, or vendor tools like Samsung Magician) works on healthy SSDs but may hang on failing drives.

## Recovery from no-boot

### Boot sequence triage

When Windows won't boot, work the layers:

| Symptom | Where it failed | First step |
|---------|----------------|------------|
| No POST, no fans, no LEDs | Power supply or motherboard | Check power, PSU |
| POST but no boot device found | Drive or BIOS settings | Check boot order; check drive is detected in BIOS |
| "Inaccessible boot device" (Win logo then crash) | BCD or boot driver | Boot to RE → `bootrec /scanos` then `/rebuildbcd` |
| Spinning dots forever | Driver hang or filesystem | Boot to RE → Startup Repair, then `chkdsk /scan` |
| Login screen reached but crash | User-mode driver/service | Safe Mode → identify recently changed driver |
| Login OK but desktop missing | Shell / profile issue | Safe Mode → check `userinit.exe` registration |

### Safe Mode access

- **From login screen**: hold Shift while clicking Restart → Troubleshoot → Advanced → Startup Settings
- **From three failed boots**: WinRE auto-triggers
- **From running Windows**: `msconfig` → Boot tab → Safe boot (revert after diagnosing!)

Once in Safe Mode, common moves:
1. Roll back last driver (Device Manager → driver properties → Roll Back)
2. Disable suspect startup item (`scripts/safe-disable-startup.ps1` works in Safe Mode too)
3. System Restore to a known-good point
4. Run `sfc /scannow` and `DISM /Online /Cleanup-Image /RestoreHealth`

### System Restore from WinRE

```
Troubleshoot → Advanced Options → System Restore
```

Picks a restore point and rolls back system files + registry + drivers (NOT personal data). Effective against recent driver/update issues. Useless if no restore points exist (Win10/11 sometimes turn off System Protection by default).

## When to escalate

Time to call professional data recovery:

- Drive doesn't show up in BIOS at all
- Drive makes clicking, grinding, or scraping sounds
- SMART status reports "Pred. Failure" AND the drive vanished mid-use
- ddrescue can't make forward progress (reading at <1 MB/min for hours)
- You opened the drive (you don't have a cleanroom; you just killed it)

Cost ranges $300 (logical recovery — bad sectors but PCB intact) to $3000+ (head transplant, platter swap). Always get a quote before committing — quoted no-recovery-no-fee outfits exist.
