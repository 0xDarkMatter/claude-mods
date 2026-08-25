# UAC Attribution — who asked for elevation?

How to attribute an unexplained UAC prompt to its caller, in the moment and after
the fact. Distilled from a real gsudo incident (2026-06-11): an unexplained
gsudo UAC prompt was traced to `npx` auto-installing the npm package `sd@0.0.3`
(a 20-line `sudo` wrapper) when the Rust `sd` wasn't found in a project prefix —
the package ran `sudo <args>`, and `sudo` on PATH was gsudo's alias.

## The 30-second playbook (when the prompt is on screen)

1. **Click "Show details" FIRST.** Note the program path, publisher, and — most
   importantly — the full command line. This is the only moment the command line
   is guaranteed visible without auditing.
2. **Then decline** (unless you initiated it). Declining is safe; the requesting
   process still ran unelevated, which is what leaves the artifacts below.
3. **Afterwards, check Security log 4688** for the caller (requires
   process-creation auditing — see Countermeasure):

   ```powershell
   Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4688;
       StartTime=(Get-Date).AddMinutes(-15)} |
     Where-Object { $_.Message -match 'gsudo|consent' } |
     ForEach-Object { [xml]$x=$_.ToXml(); $d=@{};
       $x.Event.EventData.Data | ForEach-Object { $d[$_.Name]=$_.'#text' }
       [pscustomobject]@{ Time=$_.TimeCreated; New=$d.NewProcessName;
         Parent=$d.ParentProcessName; Cmd=$d.CommandLine } }
   ```

   `ParentProcessName` + `CommandLine` is the definitive answer.

## Forensics without 4688 (auditing was off at the time)

A **declined** elevation still executes the requesting binary unelevated first,
so execution artifacts exist. Work down this ladder — all admin-gated, so do
every read in ONE elevated pass (`Start-Process powershell -Verb RunAs`, never
via gsudo itself: that would overwrite the gsudo prefetch evidence).

| Artifact | What it gives | How |
|---|---|---|
| `C:\Windows\Prefetch\<EXE>-<hash>.pf` | Last 8 run times + run count + every file/dir the process touched in its first 10s | PECmd (Eric Zimmerman, `download.ericzimmermanstools.com/PECmd.zip` — .NET 4 build runs anywhere). Raw `.pf` CreationTime = first run, LastWriteTime ≈ last run + 10s |
| All `.pf` last-written in the window | Co-executed processes → candidate parents | `Get-ChildItem C:\Windows\Prefetch *.pf` filtered by LastWriteTime |
| BAM (`HKLM:\SYSTEM\CurrentControlSet\Services\bam\State\UserSettings\<SID>`) | Per-exe last-execution FILETIME (bytes 0–7 of each value) | Decode with `[DateTime]::FromFileTimeUtc([BitConverter]::ToInt64($bytes,0))`. NOTE: BAM misses short-lived CLI processes — prefetch is the reliable source for those |
| `CONSENT.EXE-*.pf` LastWriteTime | Confirms a UAC dialog actually appeared | Same prefetch read |
| npm `_npx` cache (`npm config get cache` + `\_npx`) | Whether npx fetched+ran a registry package — directory CreationTime is second-precision | Compare against the elevation time; read the cached `package.json` and bin to see what executed |
| Claude/agent transcripts (`~\.claude\projects\**\*.jsonl`) | What commands an agent session ran at that second | Filter lines by `"timestamp":"<UTC-ISO-minute>"` — search by TIME, not keyword: the elevating string (`sudo`) may never appear in the transcript if a wrapper script/package issued it |

Cross-correlate by the second: the process whose run time is 0–5s before the
target binary's run time is the likely parent.

## Countermeasure — make the next one attributable

Enable process-creation auditing with command lines (one elevated pass):

```powershell
auditpol /set /subcategory:"{0CCE922B-69AE-11D9-BED3-505054503030}" /success:enable
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit" `
    /v ProcessCreationIncludeCmdLine_Enabled /t REG_DWORD /d 1 /f
```

(The GUID is the Process Creation subcategory — locale-proof.) Cost: modest CPU,
but the Security log (default 20 MB, rolls over) may then retain less than a day
on a busy box. Grow it if you want a real window:
`wevtutil sl Security /ms:104857600` (100 MB).

## The npx footgun (root-cause class)

`npx <cmd>` that doesn't resolve locally **auto-installs an arbitrary npm
package of that name from the registry and executes it** — no prompt in
non-interactive shells. Any short command name (`sd`, `rg`, `fd`, `z`) collides
with ancient npm squatters. Defenses:

- Never route a native CLI through `npx`. `npx --prefix <dir> sd ...` is how
  the incident happened.
- `npx --no-install <cmd>` fails instead of fetching.
- `npm config set npx-prompt true` (or rely on a Socket wrapper — see
  `supply-chain-defense`) to gate registry fetches.
- After any suspected incident, inspect `<npm-cache>\_npx\*` directories by
  CreationTime and purge unwanted entries.
