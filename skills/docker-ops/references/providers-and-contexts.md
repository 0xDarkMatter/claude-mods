# Providers and Contexts

Which engine is the docker CLI actually talking to? Most "Docker is broken" reports on a
laptop are really this question. Facts verified 2026-10-07.
`scripts/docker-doctor.py` answers it read-only.

## Contents

- [How the CLI picks an engine](#how-the-cli-picks-an-engine)
- [Provider endpoints](#provider-endpoints)
- [Telling providers apart](#telling-providers-apart)
- [Credential helpers](#credential-helpers)
- [Switching providers](#switching-providers)
- [Provider notes](#provider-notes)

## How the CLI picks an engine

Precedence, highest first:

1. `docker --context X` / `docker -H ...` on the command line
2. **`DOCKER_HOST`** in the environment
3. **`DOCKER_CONTEXT`** in the environment
4. the context stored by `docker context use` (`currentContext` in `~/.docker/config.json`)
5. the default: `unix:///var/run/docker.sock`, or `npipe:////./pipe/docker_engine` on Windows

A `DOCKER_HOST` exported years ago in a shell profile silently beats every context. When
`docker context use` "doesn't work", check `echo $DOCKER_HOST` (`$env:DOCKER_HOST`) first.

```bash
docker context ls                    # all contexts; * marks the stored one
docker context show                  # the one in effect (honours DOCKER_CONTEXT, not DOCKER_HOST)
docker context inspect <name> --format '{{.Endpoints.docker.Host}}'
```

`DOCKER_CONFIG` moves the whole config folder: contexts, credential settings, CLI plugins.

## Provider endpoints

| Provider | Context | Endpoint |
|---|---|---|
| Docker Desktop (Windows) | `desktop-linux` (`desktop-windows` for Windows containers) | `npipe:////./pipe/dockerDesktopLinuxEngine` |
| Docker Desktop (macOS) | `desktop-linux` | `unix:///Users/<you>/.docker/run/docker.sock`; `/var/run/docker.sock` links to it when enabled |
| Docker Desktop (Linux) | `desktop-linux` | `unix:///home/<you>/.docker/desktop/docker.sock` |
| OrbStack | `orbstack` | `unix:///Users/<you>/.orbstack/run/docker.sock` |
| Colima | `colima` (`colima-<profile>`) | `unix:///Users/<you>/.colima/<profile>/docker.sock` |
| Rancher Desktop | `rancher-desktop` | `~/.rd/docker.sock` (or `/var/run/docker.sock` with administrative access) |
| Podman | a context or `DOCKER_HOST` you add | `podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}'` |
| Native engine (Linux) | `default` | `unix:///var/run/docker.sock` |

Docker Desktop switches the context to `desktop-linux` when it starts. Colima sets its own
context as current. Windows' legacy `docker_engine` pipe is ambiguous: Docker Desktop
answers on it, and so can a native Windows engine or another provider.

## Telling providers apart

Trust the endpoint path first (it is the doctor's method, following docker/skills'
Desktop preflight). The `docker info` strings are clues, not proof:

```bash
docker info --format '{{.OperatingSystem}} | {{.KernelVersion}} | {{.OSType}}/{{.Architecture}}'
```

- A kernel ending in `-linuxkit` is Docker Desktop's VM. `-microsoft-standard-WSL2` means a
  WSL2 backend, either Docker Desktop's or an engine you installed inside a distro.
- `OSType` `windows` means Windows-containers mode, where Linux images will not run.
- On macOS, `ls -l /var/run/docker.sock` shows which provider owns the shared socket.
  Tools that ignore contexts (some IDEs, Testcontainers) talk to whatever owns it.

## Credential helpers

`~/.docker/config.json` names helpers, never secrets:

```json
{ "credsStore": "desktop", "credHelpers": { "123456789012.dkr.ecr.us-east-1.amazonaws.com": "ecr-login" } }
```

Each name maps to a binary `docker-credential-<name>` that must be on `PATH`: `desktop`
(ships with Docker Desktop), `osxkeychain`, `wincred`, `pass`, `secretservice`,
`ecr-login`, `gcloud`. After uninstalling Docker Desktop, a leftover `"credsStore": "desktop"`
breaks every login and private pull with "error getting credentials". Remove the key, or
install the helper. Never read or print the `auths` section; it can hold base64 credentials.

## Switching providers

1. Quit the old provider (the app, `colima stop`, `podman machine stop`). Two providers
   running at once fight over published ports and `/var/run/docker.sock`.
2. Images, containers and volumes **do not move**: each provider has its own VM disk. Move
   what matters through a registry, `docker save`/`docker load`, or a volume backup
   ([compose.md](compose.md)).
3. Select the new endpoint (`docker context use ...`), and unset any stale `DOCKER_HOST`.
4. Run `docker-doctor.py` to confirm the endpoint, the provider and the engine version.

## Provider notes

- **Docker Desktop**: a paid subscription is required for commercial use in organisations
  of 250+ employees or $10M+ annual revenue. It is free for personal use, education, small
  businesses and non-commercial open source. It now ships weekly. Since 4.75, WSL
  integration with your default distro is off by default: enable it per distro in Settings >
  Resources > WSL integration. Organisations can lock settings (`admin-settings.json`); a
  locked setting is your admin's call.
- **OrbStack** (macOS): fast and light. Free for personal, non-commercial use; commercial use is Pro.
- **Colima** (macOS, Linux): open source, built on Lima. On macOS 13+ it defaults to the
  `vz` VM type. `colima start --cpu 4 --memory 8 --vm-type vz --mount-type virtiofs`. Colima
  ships its own agent skill on its main branch (abiosoft/colima, `skills/`).
- **Rancher Desktop**: open source. Choose the `moby` engine for the docker CLI; with
  `containerd` you use `nerdctl`, and `docker` commands fail.
- **Podman 6**: rootless and daemonless. On macOS `podman machine` uses libkrun by
  default; Intel Macs, Windows 10 and cgroups v1 are no longer supported. Its Docker-
  compatible API (v1.44) serves the docker CLI and Compose through `DOCKER_HOST`.
- **WSL containers (WSLc)**: generally available in WSL 3.0.1 (`wslc.exe`), but with no
  Docker-compatible API and no Compose yet. It is not a drop-in engine for docker tooling.
- **Apple `container`** (macOS 26+, Apple silicon): Apple's own runtime, with no Docker API.
  Its agent skill triggers on Docker words too. For Dockerfile and Compose work, this skill
  applies.
