---
name: docker-ops
description: "Docker on your machine and in your repo: Dockerfile, .dockerignore, compose.yaml, BuildKit, image hardening and supply chain, plus the engine underneath (Docker Desktop, OrbStack, Colima, Podman, Rancher Desktop): contexts and sockets, ports, disk space, file sharing, emulation. Ships a repo auditor, a read-only machine doctor, an image-tag checker. Not for Kubernetes or Helm (kubernetes-ops), DDEV projects (ddev-ops), or WSL itself (windows-ops)."
when_to_use: "Use when writing or reviewing a Dockerfile or Compose file, shrinking or hardening an image, picking a base image, or when Docker misbehaves locally: 'cannot connect to the Docker daemon', 'port is already allocated', 'forbidden by its access permissions', a VM disk that only grows, slow bind mounts, an arm64/amd64 mismatch, two engines fighting. Also before any docker rm, prune or volume delete."
license: MIT
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
  owns: "dockerfile, dockerignore, compose, buildkit, image-hardening, docker-engine, docker-desktop, colima, orbstack, podman, rancher-desktop, docker-contexts, docker-disk"
  related-skills: "kubernetes-ops, ddev-ops, windows-ops, supply-chain-defense, package-manager-ops, ci-cd-ops, go-ops, rust-ops"
---

# Docker Operations

Docker on your machine and in your repo: the files you write (Dockerfile, .dockerignore,
compose.yaml) and the engine that runs them. Versions verified 2026-10-07 (Compose v5,
Docker Desktop 4.94, WSL 3.0, Podman 6); `scripts/check-docker-facts.py --live` re-checks
them weekly.

**Why:** the costly Docker mistakes are silent. A secret is copied into a layer, a datastore
listens on every interface, `compose config` pastes credentials into a log, a prune deletes
a volume someone needed. The rules below stop those first.

## Hard rules

1. **Say what is lost before anything destructive, and confirm a sweep.** Removing one
   stopped container the user named is fine on an explicit ask. `docker kill`, any `prune`,
   `compose down -v`, `volume rm`, and anything unscoped (`docker rm -f $(docker ps -aq)`)
   needs a confirmation that names what goes. A sweep counts as a sweep even when
   everything in it is stopped: scope beats state. Tiers: [destructive-commands.md](references/destructive-commands.md).
2. **Never run `docker compose config` bare.** It prints interpolated values and inlines
   `env_file` contents. Use `docker compose config --quiet` to validate, and add
   `--no-interpolate` when you need to read the file.
3. **No secrets in layers.** No `ARG`/`ENV` credentials, no `COPY .env` / `.npmrc` / keys.
   Use `RUN --mount=type=secret,id=x,required=true` (fails loudly when the secret is
   missing) and `--mount=type=ssh`. A later `RUN rm` does not remove a file from the
   earlier layer.
4. **Datastores and debug ports bind to loopback.** Write `127.0.0.1:5432:5432`, never `5432:5432`.
   On Docker Desktop, an unbound port is reachable from your LAN.
5. **Pin scanners and actions by commit SHA.** In March 2026, 76 of trivy-action's 77 tags
   were force-pushed to an infostealer (advisory GHSA-69fq-xp46-6x23). Use
   `aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25 # v0.36.0`.
   Vetting dependencies is supply-chain-defense's job.
6. **Current bases only.** Node.js 22 is the oldest supported line (20 ended 2026-04-30),
   Python 3.11 (3.10 ended 2026-10-01). Distroless images are `-debian13`. Pin a tag, and
   in production a digest. `assets/docker-facts.json` holds the floors the auditor checks.
7. **Verify a non-root image with `docker inspect --format '{{.Config.User}}'`** (it must be
   set and not `0` or `root`). `docker run img whoami` lies when the image has an ENTRYPOINT.
8. **Never start, stop or reconfigure the engine on the user's behalf.** Report that it is
   down and give the start command. Propose a settings change; don't apply it. A setting
   their admin locked is the admin's call (`docker-doctor.py` reports locks).
9. **`compose.yaml`, no `version:` line.** Compose ignores `version:` and prints a warning.
   Since Compose v5 (2025-12; v3 and v4 were skipped), builds go through Bake.
10. **Run this skill's scripts by path from the project root.** Use
    `python "<skill-dir>/scripts/x.py"`; never `cd` into the skill or call `scripts/x.py`
    relative to the project.

## Routing

| The task | Where |
|---|---|
| Dockerfile, multi-stage, BuildKit, base images, multi-platform | here + [dockerfile.md](references/dockerfile.md) |
| compose.yaml, healthchecks, profiles, watch, secrets | here + [compose.md](references/compose.md) |
| Scanning, SBOM, provenance, signing, digest pins | [supply-chain-and-scanning.md](references/supply-chain-and-scanning.md); vetting packages: supply-chain-defense |
| Which engine am I talking to, contexts, sockets, credential helpers | [providers-and-contexts.md](references/providers-and-contexts.md) |
| Port clashes, host.docker.internal, VPN subnets, reserved ports | [ports-and-networking.md](references/ports-and-networking.md) |
| The VM disk keeps growing | [disk-reclaim.md](references/disk-reclaim.md) |
| Slow bind mounts, VirtioFS, Rosetta, arm64 vs amd64 | [vmm-sharing-emulation.md](references/vmm-sharing-emulation.md) |
| A container that won't start, exits, or can't be debugged | [debugging.md](references/debugging.md) |
| Kubernetes, Helm, Gateway API, ECS | kubernetes-ops |
| A project with a `.ddev/` folder | ddev-ops (its extra services use Compose syntax from here) |
| `.wslconfig`, WSL networking modes, WSL disks in general | windows-ops ([wsl.md](../windows-ops/references/wsl.md)) |
| `npm ci` vs `npm install`, lockfiles inside a RUN | package-manager-ops |
| CI pipelines that build and push | ci-cd-ops |

## Tools

```bash
docker build --check .                                       # BuildKit's own checks first (needs the daemon)
python "<skill-dir>/scripts/docker-audit.py" .               # repo: Dockerfiles + Compose (exit 10 = findings)
python "<skill-dir>/scripts/docker-doctor.py" --ports 80,5432   # machine: engine, provider, disk, ports (read-only)
python "<skill-dir>/scripts/check-image-tags.py" --live .     # do the pinned tags exist for amd64+arm64?
python "<skill-dir>/scripts/check-docker-facts.py" --offline  # are this skill's version facts still stated?
```

- `scripts/docker-audit.py` checks Dockerfile families D1-D11 (base pinning and EOL, user,
  secrets, TLS bypasses, package hygiene, instruction semantics, pipes, build context,
  directives, healthcheck tooling, labels) and Compose families C1-C9 (obsolete `version:`,
  build+image squatting, floating tags, literal secrets, published ports, host escapes,
  hardening, readiness, undeclared resources). `--list-checks` shows each check with its
  hadolint / BuildKit / Trivy / Checkov IDs. Suppress a finding inline with
  `# docker-audit ignore=CHECK reason="..." until=YYYY-MM-DD`; a missing reason suppresses
  nothing. `--production` adds digest pins and Compose hardening.
- `scripts/docker-doctor.py` resolves the endpoint (DOCKER_HOST > DOCKER_CONTEXT > the stored
  context), names the provider from the socket or pipe path, and reports: the engine down
  or hung, two providers running, a missing credential helper, a VM disk far bigger than
  what the engine holds, Windows-reserved ports, ports held inside running WSL, admin locks.
  It never starts, prunes or compacts anything.
- `scripts/check-image-tags.py` inventories every FROM / `COPY --from=` / `image:` reference
  (Markdown code fences included). `--live` asks the registries: missing exits 10, uncertain
  (Docker Hub's 429s) exits 7.
- `scripts/check-docker-facts.py` keeps `assets/docker-facts.json` true: `--offline` in PR
  CI, `--live` weekly.

## Dockerfile in one screen

```dockerfile
# syntax=docker/dockerfile:1
FROM node:24-slim AS deps
WORKDIR /app
RUN --mount=type=bind,source=package.json,target=package.json \
    --mount=type=bind,source=package-lock.json,target=package-lock.json \
    --mount=type=cache,target=/root/.npm,sharing=locked \
    npm ci --omit=dev

FROM node:24-slim
WORKDIR /app
RUN rm -f /etc/apt/apt.conf.d/docker-clean \
 && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends tini
COPY --link --from=deps /app/node_modules ./node_modules
COPY --chown=node:node . .
USER node
HEALTHCHECK CMD ["node", "healthcheck.js"]
ENTRYPOINT ["tini", "--"]
CMD ["node", "server.js"]
```

What makes it right: `# syntax=` on line 1 (anywhere else it is a comment). Bind-mounted
manifests for an install that only reads them (keep `COPY` when the lockfile gets written
back). Cache mounts with `sharing=locked`, and the `docker-clean` hook removed so the apt
cache survives (Debian and Ubuntu images delete it after every install otherwise). Exec-form
`CMD`, so the process gets SIGTERM. A non-root `USER`. A healthcheck the image can actually
run: slim and distroless images ship no curl.
Per-language stages, multi-platform builds and base-image choice: [dockerfile.md](references/dockerfile.md).

`.dockerignore` at the context root, at least: `.git`, `.env*` (then `!.env.example`),
`node_modules`, `*.pem`, `*.key`, build output. Without it, `COPY . .` ships the history and
your secrets, and every commit busts the cache.

## Compose in one screen

```yaml
services:
  web:
    build: .
    image: ghcr.io/acme/web:dev        # registry-qualified, so `compose pull` can't fetch a stranger's image
    ports: ["127.0.0.1:3000:3000"]
    environment:
      SESSION_SECRET: ${SESSION_SECRET:?set SESSION_SECRET}
    depends_on:
      db: {condition: service_healthy}
  db:
    image: postgres:18.6-trixie
    environment: {POSTGRES_PASSWORD_FILE: /run/secrets/db_password}
    secrets: [db_password]
    healthcheck: {test: ["CMD-SHELL", "pg_isready -U postgres"], interval: 5s}
    volumes: [dbdata:/var/lib/postgresql]
volumes: {dbdata: {}}
secrets: {db_password: {file: ./db_password.txt}}
```

`service_healthy` needs a healthcheck on the dependency, or Compose fails at start.
`develop.watch` (`docker compose watch`) replaces most bind-mount dev loops. Profiles,
`include:`, overrides and env precedence are in [compose.md](references/compose.md).

## Destructive commands (summary)

| Tier | Commands | Rule |
|---|---|---|
| 1 | `docker rm <one stopped container the user named>`; `rm -f` of a container you started this session for a test | act on an explicit ask, then report |
| 2 | `docker kill`; `container/image/volume/network/builder/system prune`; `compose down -v`; `volume rm`; anything over `$(docker ps -aq)`; containers you didn't start | name what is lost, wait for a yes |
| - | `docker stop` | restartable, but in-memory state goes; warn unless it's your own test container |

`system prune --volumes` removes only anonymous volumes. `system prune -a` removes every
image no container uses: the next build re-downloads everything.

## Engines in one table

| Provider | Endpoint | Starts with |
|---|---|---|
| Docker Desktop | context `desktop-linux`: `npipe:////./pipe/dockerDesktopLinuxEngine` (Windows), `~/.docker/run/docker.sock` (macOS) | the app, or `docker desktop start` |
| OrbStack | context `orbstack`, `~/.orbstack/run/docker.sock` | the app |
| Colima | `~/.colima/<profile>/docker.sock` | `colima start` |
| Rancher Desktop | context `rancher-desktop`, `~/.rd/docker.sock` | the app |
| Podman | `podman machine inspect` (ConnectionInfo) | `podman machine start` |

`DOCKER_HOST` beats `DOCKER_CONTEXT`, and both beat `docker context use`. A forgotten
`DOCKER_HOST` in a shell profile is the usual reason "my context is ignored". Two engines
running at once fight over ports and `/var/run/docker.sock`. Docker Desktop 4.59 stopped
compacting its WSL data disk, so on Windows the disk only grows: [disk-reclaim.md](references/disk-reclaim.md).

## References

| File | Read when |
|---|---|
| [dockerfile.md](references/dockerfile.md) | Writing a Dockerfile: per-language stages, caching, multi-platform, base images, hardening |
| [compose.md](references/compose.md) | Writing compose.yaml: healthchecks, profiles, watch, include, env precedence |
| [supply-chain-and-scanning.md](references/supply-chain-and-scanning.md) | Scanning, SBOM and provenance, signing, digest pinning, base-image updates |
| [destructive-commands.md](references/destructive-commands.md) | Before removing anything: the tiers, plus kubectl, Helm and DDEV equivalents |
| [providers-and-contexts.md](references/providers-and-contexts.md) | Which engine, contexts and sockets, credential helpers, switching providers |
| [ports-and-networking.md](references/ports-and-networking.md) | Ports in use or reserved, host aliases, subnets and VPNs, rootless ports |
| [disk-reclaim.md](references/disk-reclaim.md) | VM disk images on Windows and macOS, and what is safe to reclaim |
| [vmm-sharing-emulation.md](references/vmm-sharing-emulation.md) | VM backends, file-sharing speed, Rosetta and QEMU emulation |
| [debugging.md](references/debugging.md) | Containers that exit, hang or can't be entered; build debugging |

Assets: `assets/Dockerfile.template` and `assets/compose.template.yaml` are starters that
pass the auditor clean. `assets/docker-facts.json` is the version catalog.
