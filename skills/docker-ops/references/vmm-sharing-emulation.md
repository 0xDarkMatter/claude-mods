# VM Backends, File Sharing and Emulation

On Windows and macOS every container runs inside a Linux VM. The VM's backend decides how
fast bind mounts are and whether amd64 images run on Apple silicon. Facts verified
2026-10-07. Some Docker Desktop settings move often, so check the version you have.

## Contents

- [Docker Desktop backends](#docker-desktop-backends)
- [File sharing and bind-mount speed](#file-sharing-and-bind-mount-speed)
- [Emulation: running the other architecture](#emulation-running-the-other-architecture)
- [Lima, Colima and Podman](#lima-colima-and-podman)

## Docker Desktop backends

| Platform | Options | Notes |
|---|---|---|
| macOS (Apple silicon) | Apple Virtualization framework (default), Docker VMM | Docker VMM runs Docker's own hypervisor since 4.86 (libkrun before that), without Rosetta; Docker's pages disagree on whether it is still Beta |
| macOS (Intel) | Apple Virtualization framework; HyperKit (deprecated) | |
| Windows | WSL 2 (default), Hyper-V, Docker VMM | WSL 2 is the one with tooling; WSL settings themselves are in windows-ops' [wsl.md](../../windows-ops/references/wsl.md) |

Settings > General (macOS: "Virtual Machine Options") chooses the backend. Switching
backends does not carry images over: treat it like switching providers.

## File sharing and bind-mount speed

- macOS: VirtioFS is the default file sharing; the old osxfs was removed in 4.80. Bind
  mounts are still slower than native, worst for trees with many small files (`node_modules`,
  `vendor`).
- Windows: **keep the code in the WSL filesystem** (`\\wsl$\Ubuntu\home\you\src`), not under
  `/mnt/c`. Crossing the Windows-to-Linux boundary on every file read is the slow path, and
  inotify file watching does not work across it.
- Patterns that avoid the slow path:
  - `develop.watch` (sync instead of mounting): [compose.md](compose.md)
  - a named volume over the dependency folder: `- node_modules:/app/node_modules`
    alongside `- .:/app`
  - mount only `src/`, not the whole repo
- Ownership: files a container creates in a bind mount belong to the container's UID. On a
  native Linux engine that is a real UID on your disk; run the container as your UID (`user:
  "${UID}:${GID}"`) for dev mounts.

## Emulation: running the other architecture

- `exec format error` when a container starts means the image's architecture doesn't match
  the host's, and nothing is emulating it.
- Apple silicon with Docker Desktop: amd64 images run through Rosetta (when enabled in
  Settings > General) or QEMU. Rosetta is faster. Docker's settings page and its 4.25 notes
  disagree on the default, so check the toggle. Apple says Rosetta for Linux VMs is not
  planned for deprecation, even as Rosetta for Mac apps narrows after macOS 27.
- Native Linux: register QEMU handlers with `docker run --privileged --rm tonistiigi/binfmt --install all`.
  That is a privileged container changing host kernel settings, so it is the user's call.
- `--platform linux/amd64` on `run` or `FROM` forces emulation: it works, slowly. Build
  multi-platform images instead ([dockerfile.md](dockerfile.md)), so each host runs its own
  architecture natively.
- `docker image inspect --format '{{.Os}}/{{.Architecture}}' <image>` shows what you pulled;
  `docker buildx imagetools inspect <image>` shows what the registry offers.

## Lima, Colima and Podman

- **Lima 2.x**: VM type `vz` by default on macOS 13.5+ (`qemu` elsewhere). Mounts are
  `virtiofs` with vz and `9p` with qemu; `reverse-sshfs` was the old default.
- **Colima**: built on Lima; defaults to `vz` on macOS 13+ (its yaml template still says
  qemu, but the code picks vz). For amd64 on Apple silicon:
  `colima start --vm-type vz --vz-rosetta`.
- **Podman 6** on macOS uses libkrun by default (Apple Hypervisor before 6.0). After an
  upgrade, check which provider an existing machine runs on with `podman machine inspect`
  before you tune it.
