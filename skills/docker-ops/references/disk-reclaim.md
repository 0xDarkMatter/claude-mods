# Disk Reclaim

Container engines on Windows and macOS keep everything inside a VM disk image. Deleting
images frees space *inside* that disk; the file on your drive often does not shrink. Facts
verified 2026-10-07. `docker-doctor.py` reports each disk image's size next to what the
engine actually holds, and never compacts anything.

## Contents

- [First: what is using the space](#first-what-is-using-the-space)
- [What is safe to remove](#what-is-safe-to-remove)
- [Windows: Docker Desktop's WSL disk](#windows-docker-desktops-wsl-disk)
- [Windows: WSL's own tools](#windows-wsls-own-tools)
- [macOS](#macos)
- [Linux](#linux)

## First: what is using the space

```bash
docker system df            # images, containers, volumes, build cache: size and reclaimable
docker system df -v         # per image, per volume
python "<skill-dir>/scripts/docker-doctor.py"   # the VM disk file vs what the engine holds
```

`docker system df` counts objects inside the engine, not the disk file. When the disk file
is 35 GB and `system df` says 6 GB, the difference is freed space the VM disk never gave
back. Pruning cannot recover that; only compaction can.

## What is safe to remove

Each step is a Tier 2 command ([destructive-commands.md](destructive-commands.md)): list
it, say what goes, confirm.

| Command | Frees | Cost |
|---|---|---|
| `docker builder prune --filter until=168h` | build cache older than a week | slower first builds |
| `docker image prune` | dangling (untagged) images | none |
| `docker image prune -a --filter until=720h` | images no container uses, unused for 30 days | re-downloads |
| `docker container prune` | stopped containers, on the whole engine | their writable layers |
| `docker volume prune` | anonymous volumes only | rarely anything you want |
| `docker volume rm <name>` | that volume's data | **data**: back it up first |

Shrinking the engine's data does not shrink the VM disk file on Windows. Read on.

## Windows: Docker Desktop's WSL disk

- The data disk is `docker_data.vhdx`, by default under `%LOCALAPPDATA%\Docker\wsl\disk\`.
  Settings > Resources > Advanced > "Disk image location" moves it. Moving it to another
  drive failed before 4.92, and an interrupted move could delete the image in 4.91 and
  earlier, so update Docker Desktop before you move.
- **Docker Desktop 4.59 (2026-02-02) "temporarily disabled VHDX compaction for the WSL data
  disk"**, and no release through 4.94 turned it back on. Since then the file only grows.
  `scripts/check-docker-facts.py --live` watches the release notes for compaction coming back.
- The route people use is a community procedure, not one Docker supports. It needs
  administrator rights and has data risk, so it is the user's to run, after a backup or
  with nothing in the engine they can't rebuild:
  1. Quit Docker Desktop, then `wsl --shutdown`.
  2. Attach the disk to a WSL distro and trim the filesystem, so freed blocks are marked
     free: `wsl --mount <path-to-docker_data.vhdx> --vhd`, then in the distro
     `sudo fstrim -v <mount point>`, then `wsl --unmount <path>`.
  3. Compact the file as administrator: `Optimize-VHD -Path <path> -Mode Full` (needs the
     Hyper-V PowerShell module). Without Hyper-V, use diskpart: `select vdisk file=<path>`,
     `attach vdisk readonly`, `compact vdisk`, `detach vdisk`.
  4. Start Docker Desktop and check `docker system df` against the new file size.
- Cheaper alternative: if nothing in the engine matters, Troubleshoot > "Clean / Purge data"
  resets the disk. That deletes every image, container and volume (Tier 2, explicitly).

## Windows: WSL's own tools

For WSL distros in general (the full picture, per WSL version, is windows-ops'
[wsl.md](../../windows-ops/references/wsl.md)):

- `wsl --manage <distro> --set-sparse true` has been refused since WSL 2.5.6 unless you add
  `--allow-unsafe`; Microsoft cites possible data corruption. WSL 3.0.2 (pre-release in
  October 2026) drops that requirement.
- `wsl --manage <distro> --compact` exists from WSL 2.9.8 / 3.0.1. It needs the distro
  stopped and works on its `.vhdx`. Whether it can reach Docker Desktop's data disk, which
  is not a registered distro, is unverified: don't promise it.

## macOS

- **Docker Desktop**: `Docker.raw` under `~/Library/Containers/com.docker.docker/Data/vms/0/data/`
  is a sparse file. Finder shows its maximum size; `du -h Docker.raw` shows the real usage.
  Space comes back as images are deleted. The "Disk usage limit" in Settings caps the
  maximum. The FAQ's `docker/desktop-reclaim-space` image was last updated in 2019: don't
  rely on it.
- **OrbStack**: `data.img` (under `~/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data`)
  is sparse and shrinks by itself when data is deleted.
- **Colima**: frees space when it starts (since 0.5.0). For a manual trim, run
  `colima ssh -- sudo fstrim -a`. The disk size can only grow (`colima.yaml`).
- **Podman machine**: the machine image lives under `~/.local/share/containers/podman/machine/`.
  Prune inside it with `podman system prune` (Tier 2), or recreate the machine.

## Linux

A native engine stores everything under `/var/lib/docker` (the `DockerRootDir` in
`docker info`), so pruning frees disk space directly. Keep the build cache bounded with
`builder.gc` in `/etc/docker/daemon.json` (`{"builder": {"gc": {"enabled": true, "defaultKeepStorage": "20GB"}}}`).
To move the data root, stop the engine, move the folder, then set `"data-root"`. That is an
admin change: propose it.
