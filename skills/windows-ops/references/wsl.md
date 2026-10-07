# WSL: Configuration, Networking and Disks

Windows Subsystem for Linux 2, as of stable WSL 3.0.1 (3.0.2 is a pre-release). Verified
2026-10-07 against Microsoft's WSL documentation and WSL's own usage strings. Docker
Desktop's WSL disk and its engine are docker-ops' job; DNS fault-finding beyond WSL's
settings is net-ops'.

## Contents

- [Two config files, and the 8-second rule](#two-config-files-and-the-8-second-rule)
- [.wslconfig keys that matter](#wslconfig-keys-that-matter)
- [wsl.conf essentials](#wslconf-essentials)
- [Networking modes](#networking-modes)
- [Hyper-V firewall](#hyper-v-firewall)
- [DNS](#dns)
- [Files across the boundary](#files-across-the-boundary)
- [Disks: where they live, growing and shrinking](#disks-where-they-live-growing-and-shrinking)
- [Diagnosing](#diagnosing)

## Two config files, and the 8-second rule

| | `%UserProfile%\.wslconfig` | `/etc/wsl.conf` (inside a distro) |
|---|---|---|
| Scope | the WSL 2 VM, for every distro | one distro (WSL 1 or 2) |
| Holds | memory, CPUs, networking mode, firewall, disk defaults | systemd, automount, generated DNS files, interop, default user |
| Edit with | the **WSL Settings** app (Start menu), or by hand | `sudo` editor inside the distro |

- **Changes apply only after the VM fully stops.** Closing the terminal is not enough: WSL
  keeps running for about 8 seconds (longer with `vmIdleTimeout`). Check with
  `wsl --list --running` ("There are no running distributions"), or force it with
  `wsl --shutdown` (stops every distro) or `wsl --terminate <distro>` (one distro).
- **A malformed `.wslconfig` is ignored silently**: WSL starts with defaults and says
  nothing. After an edit, confirm the setting took (`wslinfo --networking-mode`, `free -h`, `nproc`).
- Paths need escaped backslashes (`kernel=C:\\Tools\\vmlinux`). Sizes take units (`8GB`,
  `512MB`); a bare number means bytes.

## .wslconfig keys that matter

`[wsl2]` section (all apply to WSL 2 only):

| Key | Default | Notes |
|---|---|---|
| `memory` | 50% of Windows RAM | the VM's ceiling; the page cache counts against it |
| `processors` | all logical processors | |
| `swap` | 25% of RAM, rounded up to a GB | `0` disables swap |
| `networkingMode` | `nat` | `nat`, `mirrored`, `consomme`, `none`; `bridged` deprecated (see below) |
| `localhostForwarding` | `true` | NAT: Linux ports reachable as `localhost:port` from Windows. **Ignored in mirrored mode** |
| `dnsTunneling` | `true` | answers DNS through a virtualisation channel instead of packets; better with VPNs |
| `dnsProxy` | `true` | **NAT mode only**: Linux DNS points at the NAT; `false` copies Windows' DNS servers |
| `firewall` | `true` | Windows Firewall and Hyper-V firewall rules filter WSL traffic |
| `autoProxy` | `true` | Linux inherits Windows' HTTP proxy settings |
| `defaultVhdSize` | 1 TB | the maximum size of *new* distro disks |
| `vmIdleTimeout` | `60000` ms | idle time before the VM shuts down |

`[general]`: `instanceIdleTimeout` (`15000` ms before an idle distro stops; `-1` disables
auto shutdown) and `distributionInstallPath` (default `%LocalAppData%\wsl` for new installs).

`[experimental]`: `autoMemoryReclaim` (`dropCache` by default, or `gradual`, or `disabled`),
`sparseVhd` (new disks are created sparse), `hostAddressLoopback` and `ignoredPorts`
(mirrored mode only), `dnsTunnelingIpAddress` (default `10.255.255.254`), `bestEffortDnsParsing`.

Many of the networking keys (`networkingMode`, `firewall`, `dnsTunneling`, `ignoredPorts`,
`hostAddressLoopback`) need Windows 11 22H2 or later. On Windows 10, WSL quietly uses NAT.

## wsl.conf essentials

```ini
[boot]
systemd=true                 # WSL 2; needed by snap, many services and some dev tools
[automount]
options="metadata,umask=022" # Linux permissions on /mnt/c files (stored as NTFS metadata)
[network]
generateResolvConf=true      # false to hand-write /etc/resolv.conf
hostname=devbox
[interop]
appendWindowsPath=false      # stop Windows PATH entries slowing every command lookup
[user]
default=dev
```

`[boot] command=` runs as root at every start. `[automount] enabled=false` stops mounting
Windows drives under `/mnt`.

## Networking modes

| Mode | What it is |
|---|---|
| `nat` (default) | the VM sits behind NAT on its own subnet. Since WSL 2.3.25, if NAT fails WSL falls back to Consomme |
| `mirrored` | Windows' network interfaces are mirrored into Linux: IPv6, multicast, better VPN behaviour, LAN reachability |
| `consomme` | user-mode networking (formerly called `virtioproxy`) |
| `bridged` | deprecated since WSL 2.4.5 |
| `none` | no network |

Reachability:

| From → to | NAT | Mirrored |
|---|---|---|
| Windows → a Linux server | `localhost:port` (via `localhostForwarding`) | `localhost:port` |
| Linux → a Windows server | the Windows host IP: `ip route show default` gives the gateway | `127.0.0.1` (IPv6 `::1` is not supported) |
| another LAN machine → a Linux server | `netsh interface portproxy` to the VM's IP (`wsl hostname -I`), an admin change | directly, once the Hyper-V firewall allows inbound |
| IPv6 | no | yes |

Bind servers to `0.0.0.0` (not `127.0.0.1`) when anything outside the VM must reach them.
In mirrored mode, `ignoredPorts` lets a Linux process bind a port Windows already uses, for
Linux-only traffic. `hostAddressLoopback=true` lets the two sides reach each other on the
host's other IPv4 addresses, not just `127.0.0.1`.

## Hyper-V firewall

With WSL 2.0.9+ on Windows 11 22H2+, the Hyper-V firewall filters WSL traffic by default
(`firewall=true`). In mirrored mode, inbound connections from the LAN are blocked until a
rule allows them. Both of these are admin changes to the firewall, so propose them; never
run them for the user:

```powershell
# allow all inbound to WSL VMs
Set-NetFirewallHyperVVMSetting -Name '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -DefaultInboundAction Allow
# or one port only
New-NetFirewallHyperVRule -Name "WslWeb" -DisplayName "WSL web" -Direction Inbound -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -Protocol TCP -LocalPorts 80
```

## DNS

- With `dnsTunneling` on (the default on Windows 11 22H2+), `/etc/resolv.conf` points at
  `10.255.255.254` and Windows resolves the names, so VPN split-DNS and NRPT rules apply
  inside WSL too.
- `/etc/resolv.conf` and `/etc/hosts` are written by WSL at start. To pin your own DNS, set
  `[network] generateResolvConf=false` in wsl.conf, `wsl --shutdown`, then write the file
  yourself.
- Deeper DNS fault-finding (resolvers, VPN hooks, DoH) belongs to net-ops.

## Files across the boundary

- **Keep a project on the side whose tools use it.** Linux tools on Linux files
  (`~/src`, which Windows sees as `\\wsl.localhost\<distro>\home\<you>\src`); Windows tools
  on Windows files. Windows drives appear under `/mnt/c` through DrvFs, which is much slower
  for trees with many small files (`node_modules`, `vendor`, `.git`).
- File watchers (Vite, webpack, `inotifywait`) running in Linux do not get reliable events
  for changes Windows applications make under `/mnt/c`. A dev server watching `/mnt/c`
  misses edits: move the project into the Linux filesystem, or poll.
- Files under `/mnt/c` show as owned by your user with fixed permissions unless the drive is
  mounted with `metadata` (above). Case sensitivity is per directory (`fsutil file
  setCaseSensitiveInfo`), off by default on Windows drives.
- `WSLENV` shares named environment variables across the boundary, with path translation
  flags (`/p`, `/l`).

## Disks: where they live, growing and shrinking

Each WSL 2 distro is one `ext4.vhdx` that grows as you write and, by default, never shrinks.

Find a distro's disk (it's in the per-user `Lxss` registry key, as `BasePath`):

```powershell
(Get-ChildItem HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss |
  Where-Object { $_.GetValue("DistributionName") -eq 'Ubuntu' }).GetValue("BasePath") + "\ext4.vhdx"
```

Store-installed distros live under `%LocalAppData%\Packages\<publisher>\LocalState`. Newer
installs go under `%LocalAppData%\wsl` (`distributionInstallPath`).

| Task | Command | Notes |
|---|---|---|
| how full is it | `wsl.exe --system -d <distro> df -h /mnt/wslg/distro` | "Size" is the maximum (1 TB by default since WSL 0.58.0; 512 GB, then 256 GB, before that) |
| grow the maximum | `wsl --manage <distro> --resize 2TB` | WSL 2.5+; no decimals (`2.5TB` fails) |
| move it | `wsl --manage <distro> --move D:\WSL\Ubuntu` | |
| release freed space automatically | `wsl --manage <distro> --set-sparse true` | WSL 2.5.6 to 3.0.1 refuse without `--allow-unsafe`, citing possible data corruption; 3.0.2 (pre-release) calls it experimental and drops the flag. `[experimental] sparseVhd=true` makes new disks sparse |
| shrink the file now | `wsl --manage <distro> --compact` | WSL 2.9.8 / 3.0.1+; the distro must be stopped; `.vhdx` only |
| shrink on older WSL | `fstrim` inside, `wsl --shutdown`, then `Optimize-VHD -Path <vhdx> -Mode Full` (Hyper-V module) or diskpart `compact vdisk` | administrator |

Back up a distro before any of the shrink paths: `wsl --export <distro> <file>.tar`.
Compaction and sparse conversion rewrite the disk file, and WSL's own warning about sparse
disks is the reason. They are the user's call, after the backup.

A disk that fails to mount, or comes up read-only, can be checked from another distro:
`wsl --mount <path-to-ext4.vhdx> --vhd --bare`, then `e2fsck` on the device it gets (find it
with `lsblk`). Docker Desktop's data disk is not a registered distro: see docker-ops'
`references/disk-reclaim.md`.

## Diagnosing

```powershell
wsl --version             # WSL, kernel and WSLg versions (Store WSL; "not recognised" = old inbox WSL)
wsl --status              # default distro and version
wsl -l -v                 # distros, state, WSL 1 or 2
wsl --list --running
wsl -e wslinfo --networking-mode   # the mode actually in effect (nat, mirrored, ...)
```

- `wslinfo` (inside a distro) also takes `--version`, `--vm-id`, `--msal-proxy-path`, and
  `-n` (no trailing newline, for scripts).
- **`wsl.exe` prints UTF-16LE.** A script that pipes `wsl -l` into `grep`, `findstr` or
  Python sees a NUL between every character. Set `WSL_UTF8=1` in the calling environment
  (WSL 0.64.0+), or decode as UTF-16.
- `wsl -e <cmd> <args>` runs a program with no shell. `wsl -- bash -c '...'` goes through a
  shell, so `$VARS` expand inside Linux: quote for the Linux side.
- Crash dumps go to `%Temp%\wsl-crashes` (`crashDumpFolder`). `debugConsole=true` opens a
  `dmesg` console at start (Windows 11).
- WSL containers (`wslc.exe`, generally available in WSL 3.0.1) run containers without a
  distro, but offer no Docker-compatible API or Compose yet. For Docker, see docker-ops.
