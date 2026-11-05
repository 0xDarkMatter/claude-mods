# Dockerfile Patterns

How to write a Dockerfile that builds fast, ships small, and gives an attacker nothing to
work with. Tags verified 2026-10-07. Re-check them with
`scripts/check-image-tags.py --live` before you copy one.

## Contents

- [Base images](#base-images)
- [The BuildKit toolkit](#the-buildkit-toolkit)
- [Cache mounts by package manager](#cache-mounts-by-package-manager)
- [Secrets and SSH at build time](#secrets-and-ssh-at-build-time)
- [Per-language stages](#per-language-stages)
- [Multi-platform builds](#multi-platform-builds)
- [Hardening checklist](#hardening-checklist)
- [Verify before you ship](#verify-before-you-ship)

## Base images

| Family | Example | Shell / package manager | Pick it when |
|---|---|---|---|
| Distroless | `gcr.io/distroless/static-debian13:nonroot` | none | static binaries (Go, Rust musl): the smallest attack surface |
| Distroless runtime | `gcr.io/distroless/nodejs24-debian13:nonroot`, `java25-debian13` | none | a runtime with nothing else; entrypoint is the runtime itself |
| Chainguard | `cgr.dev/chainguard/node` | none (the `-dev` variants add a shell and apk) | minimal, frequently rebuilt, non-root by default |
| Debian slim | `node:24-slim`, `python:3.14-slim` (trixie) | sh + apt | glibc compatibility with a small footprint: the default |
| Alpine | `node:24-alpine` | sh + apk | small, but musl libc: some native modules, Python wheels and DNS edge cases break |
| Full | `node:24`, `golang:1.27-trixie` | everything | build stages only |

Distroless publishes `-debian13` builds only. The `-debian12` images stopped being built in
September 2026: their tags still resolve but get no security fixes. Prefer
`gcr.io/distroless/static-debian13:nonroot` over the unsuffixed `static:nonroot`.

Pinning: a tag for readability, plus a digest for reproducibility in production:
`FROM node:24-slim@sha256:<digest>`. Let Renovate or Dependabot move the digest; a hand-kept
digest goes stale silently. Runtime floors (what `docker-audit.py` calls `base-eol`):
Node.js 22, Python 3.11, PHP 8.2, Go 1.26.

## The BuildKit toolkit

```dockerfile
# syntax=docker/dockerfile:1
# check=error=true
```

- **`# syntax=` must be line 1.** A parser directive after any comment, blank line or
  instruction is just a comment, and nothing warns you (`docker-audit.py`: `directive-ignored`).
- **`# check=error=true`** makes BuildKit's build checks fail the build. Pair it with
  `docker build --check .` in CI. `# check=skip=JSONArgsRecommended` turns one check off.
- **Order layers from least to most frequently changed**: base, system packages, dependency
  manifests, install, source. A cache miss at one layer rebuilds every layer after it.
- **`COPY --link`** makes a layer independent of the ones below it, so a base-image bump
  reuses it. Use a numeric `--chown=10001:10001` with it: user names are not resolved in a
  linked layer.
- **`COPY --chmod=0755`** sets the mode without an extra `RUN chmod` layer.
- **Heredocs** keep multi-line scripts readable. The body runs under `/bin/sh`, so start it
  with `set -eux`:
  ```dockerfile
  RUN <<EOF
  set -eux
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates
  EOF
  ```
- **Bind-mount manifests** into an install that only reads them (`npm ci`, `pip install -r`,
  `go mod download`): `--mount=type=bind,source=package-lock.json,target=package-lock.json`.
  Keep `COPY` when the install writes the lockfile back.

## Cache mounts by package manager

Cache mounts keep downloads between builds and out of the image. They replace the old
`rm -rf /var/lib/apt/lists/*` and `--no-cache` idioms, which Docker's own skills stopped
recommending in 2026. Use `sharing=locked` for managers that cannot share a cache
concurrently (apt, apk).

| Manager | Mount target(s) | Notes |
|---|---|---|
| apt | `/var/cache/apt` and `/var/lib/apt`, both `sharing=locked` | first `rm -f /etc/apt/apt.conf.d/docker-clean`, or the downloaded .debs are deleted after every install |
| apk | `/etc/apk/cache`, `sharing=locked` | drop `--no-cache` when the mount is there |
| npm | `/root/.npm` | `npm ci`, never `npm install` |
| pnpm | `/root/.local/share/pnpm/store` | `pnpm install --frozen-lockfile` |
| Yarn (Berry) | `/root/.yarn/berry/cache` | `yarn install --immutable` |
| pip | `/root/.cache/pip` | or `--no-cache-dir` without a mount |
| uv | `/root/.cache/uv` | set `UV_LINK_MODE=copy` (a cache mount is another filesystem) |
| Go | `/go/pkg/mod` and `/root/.cache/go-build` | |
| Cargo | `/usr/local/cargo/registry` and `/app/target` | copy the binary out of `target` in the same RUN: the mount is gone afterwards |
| Maven / Gradle | `/root/.m2` / `/root/.gradle` | |
| Composer | `/tmp/composer-cache` with `COMPOSER_CACHE_DIR` set to it | `composer install --no-dev --optimize-autoloader` |

As root, `~` is `/root`. After a `USER` switch, point the target at that user's home and add
`uid=`.

## Secrets and SSH at build time

```dockerfile
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc,required=true npm ci
```
```bash
docker build --secret id=npmrc,src=$HOME/.npmrc .
```

`required=true` turns a forgotten `--secret` into a build failure, where otherwise you would
get a build that silently installed nothing private. Dockerfile 1.10+ can also expose a
secret as an environment variable: `--mount=type=secret,id=token,env=GITHUB_TOKEN`.

SSH for private Git dependencies: put the host's key line in `known_hosts` (GitHub publishes
its keys) and forward one key, not the whole agent:

```dockerfile
RUN mkdir -p -m 0700 ~/.ssh \
 && echo "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl" >> ~/.ssh/known_hosts
RUN --mount=type=ssh,required=true git clone git@github.com:acme/private-lib.git
```
```bash
docker build --ssh default=$HOME/.ssh/deploy_key .
```

Never `StrictHostKeyChecking=no`. A build-time `ssh-keyscan` trusts whichever key answers.

## Per-language stages

**Go**: a static binary on distroless:

```dockerfile
# syntax=docker/dockerfile:1
FROM --platform=$BUILDPLATFORM golang:1.27-trixie AS build
WORKDIR /src
RUN --mount=type=bind,source=go.mod,target=go.mod --mount=type=bind,source=go.sum,target=go.sum \
    --mount=type=cache,target=/go/pkg/mod go mod download
ARG TARGETOS TARGETARCH
RUN --mount=type=bind,target=. --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w" -o /out/app ./cmd/app

FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=build /out/app /app
ENTRYPOINT ["/app"]
```

**Rust**: build with cache mounts, then copy the binary out inside the same RUN. Use
`gcr.io/distroless/cc-debian13:nonroot` for a glibc binary, or `static-debian13` for an
`x86_64-unknown-linux-musl` one. The builder is `rust:1.99-slim-trixie`.

**Node.js**: install production dependencies in their own stage:

```dockerfile
FROM node:24-slim AS deps
WORKDIR /app
RUN --mount=type=bind,source=package.json,target=package.json \
    --mount=type=bind,source=package-lock.json,target=package-lock.json \
    --mount=type=cache,target=/root/.npm npm ci --omit=dev

FROM node:24-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci
COPY . .
RUN npm run build

FROM gcr.io/distroless/nodejs24-debian13:nonroot
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
CMD ["dist/server.js"]
```

The distroless Node.js image's entrypoint is `node`, so `CMD` names the script only.

**Python**: uv with a locked environment:

```dockerfile
FROM python:3.14-slim AS build
COPY --from=ghcr.io/astral-sh/uv:0.12.23 /uv /uvx /bin/
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PYTHON_DOWNLOADS=never
WORKDIR /app
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --locked --no-install-project --no-dev
COPY . .
RUN --mount=type=cache,target=/root/.cache/uv uv sync --locked --no-dev

FROM python:3.14-slim
RUN useradd --uid 10001 --no-create-home app
COPY --from=build --chown=10001:10001 /app /app
ENV PATH="/app/.venv/bin:$PATH" PYTHONUNBUFFERED=1
USER 10001
CMD ["python", "-m", "app"]
```

Pin uv to an exact version (never `:latest`). `--locked` fails when `uv.lock` is stale,
where otherwise uv would rewrite it during the build.

**Java**: build on `eclipse-temurin:25-jdk-noble` with a `/root/.m2` or `/root/.gradle`
cache mount. Run on `eclipse-temurin:25-jre-noble` or `gcr.io/distroless/java25-debian13:nonroot`.
Temurin 25 is the current LTS. For the smallest runtime, build a `jlink` image of just the
modules you use.

**PHP**: run `composer install --no-dev --optimize-autoloader --no-interaction` in a
`composer:2.10` stage, then copy `vendor/` into `php:8.4-fpm-trixie`. For a Craft or Laravel
site under DDEV, ddev-ops owns local dev. This file covers only the production image.

## Multi-platform builds

```bash
docker buildx build --platform linux/amd64,linux/arm64 -t ghcr.io/acme/app:1.4.0 --push .
docker buildx imagetools inspect ghcr.io/acme/app:1.4.0     # lists one manifest per platform
```

- Cross-compile instead of emulating: `FROM --platform=$BUILDPLATFORM` for the build stage,
  then `TARGETOS`/`TARGETARCH` into the compiler (Go above). Under QEMU emulation a native
  arm64 build is often 5-20x slower.
- For heavy builds, give Buildx a native node per architecture
  (`docker buildx create --append`) or use a cloud builder.
- Docker Desktop keeps multi-platform images locally only with the containerd image store
  enabled. Without it, `--load` takes one platform.
- `exec format error` at runtime means the image's platform does not match the host's:
  [vmm-sharing-emulation.md](vmm-sharing-emulation.md).

## Hardening checklist

- [ ] A non-root `USER`, numeric (`USER 10001`). Kubernetes' `runAsNonRoot` can only check a
      numeric UID, so a user *name* fails admission.
- [ ] Nothing writes outside `/tmp` and declared volumes, so the container runs with
      `--read-only --tmpfs /tmp`.
- [ ] No shell or package manager in the final stage where the app doesn't need one.
- [ ] Exec-form `CMD`/`ENTRYPOINT`. If the app doesn't reap children, use `tini` or
      `docker run --init`.
- [ ] A `HEALTHCHECK` the image can run: the app's own binary or script, not curl on slim or
      distroless. For distroless under Compose, run a sidecar that shares the service's
      network: [compose.md](compose.md).
- [ ] `LABEL org.opencontainers.image.source=...` (also `.revision` and `.version`) so
      scanners and registries can link the image back to its source.
- [ ] Run with `--cap-drop=ALL` (add back only what the app needs) and
      `--security-opt no-new-privileges`.

## Verify before you ship

```bash
docker build --check .                                        # BuildKit build checks
python "<skill-dir>/scripts/docker-audit.py" . --production   # secrets, users, pins, context
docker inspect --format '{{.Config.User}}' app:1.4.0          # must be set, not 0/root
docker history --no-trunc app:1.4.0 | grep -iE 'token|password|secret'   # nothing
docker image ls app:1.4.0 --format '{{.Size}}'
```

`dive app:1.4.0` shows which layer holds the weight. `docker buildx history` replays a
past build, with its logs and timings.
