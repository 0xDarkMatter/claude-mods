# Debugging Containers and Builds

A container that exits, hangs, or has no shell to step into, and builds that pass locally
but fail in CI.

## Contents

- [It exits straight away](#it-exits-straight-away)
- [Getting inside an image with no shell](#getting-inside-an-image-with-no-shell)
- [Health, events and resources](#health-events-and-resources)
- [Build debugging](#build-debugging)
- [Works locally, fails in CI](#works-locally-fails-in-ci)

## It exits straight away

```bash
docker logs --tail 100 <container>
docker inspect --format '{{.State.ExitCode}} oom={{.State.OOMKilled}} {{.State.Error}}' <container>
```

| Exit code | Usually |
|---|---|
| 0 | the command finished: the main process wasn't a long-running server, or it daemonised itself |
| 1 | the app's own error: read the logs |
| 125 | Docker couldn't create the container (bad flag, a port in use, a missing volume driver) |
| 126 | the command exists but can't run (no execute bit, a directory) |
| 127 | command not found, **or a script with Windows line endings**: `/bin/sh^M` doesn't exist |
| 137 | killed by SIGKILL: out of memory (`OOMKilled=true`), or `docker kill` / a stop timeout |
| 139 | segmentation fault: often a musl/glibc mismatch (an Alpine image with glibc binaries) |
| 143 | SIGTERM: a normal stop |

`exec format error` means the wrong architecture ([vmm-sharing-emulation.md](vmm-sharing-emulation.md)).
`no such file or directory` for a file that is plainly there means a CRLF shebang or a
dynamic binary missing its loader (glibc on Alpine, anything on scratch). Keep shell scripts
LF in `.gitattributes` (`*.sh text eol=lf`).

## Getting inside an image with no shell

Distroless and scratch images have no shell, by design. Bring the tools to the container
rather than adding them to the image:

```bash
# a toolbox sharing the container's process and network namespaces
docker run --rm -it --pid=container:app --network=container:app nicolaka/netshoot:v0.16
# the filesystem, read-only, from a throwaway container
docker run --rm -it --volumes-from app --entrypoint sh busybox:1.37
```

- Docker Desktop's `docker debug <container>` opens a shell with tools injected, without
  changing the image.
- Distroless ships `:debug` tag variants (with busybox) for local investigation. Never
  deploy them.
- Pin and verify a toolbox image's tag before running it: it runs with the container's privileges.

## Health, events and resources

```bash
docker inspect --format '{{json .State.Health}}' app      # last healthcheck results with output
docker events --since 10m --filter container=app          # start/die/oom/health_status events
docker stats --no-stream                                  # CPU, memory against the limit
docker top app                                            # processes inside
```

A healthcheck that is always `starting` usually runs a tool the image doesn't have
(`docker-audit.py`: `healthcheck-tool-missing`), or its `start_period` is shorter than the
app's warm-up.

## Build debugging

```bash
docker build --progress=plain --no-cache-filter build .   # full logs; re-run one stage uncached
docker buildx history ls                                   # recent builds
docker buildx history logs <ref>                           # logs of a past build
docker build --target build -t app:debug . && docker run --rm -it app:debug sh   # stop at a stage
```

- A step that "can't find" a file the repo has: `.dockerignore` excludes it
  (`docker-audit.py`: `copy-ignored-file`), or the path is relative to the wrong context.
- A cache that never hits: a `COPY . .` too early, a `--build-arg` whose value changes every
  build (dates, commit SHAs), or a base image that moved.

## Works locally, fails in CI

| Difference | Check |
|---|---|
| Architecture: arm64 laptop, amd64 runner | build with `--platform`; `docker buildx imagetools inspect` the base |
| Secrets: present locally, missing in CI | `--mount=type=secret,...,required=true` makes this fail early |
| Cache: warm locally, cold in CI | `--cache-from` / `--cache-to type=gha` or `type=registry` |
| Line endings: CRLF from a Windows checkout | `.gitattributes`, and exit code 127 above |
| `.dockerignore`: a file ignored only on one side | `docker-audit.py` against the CI checkout |
| A floating tag that moved between runs | pin digests ([supply-chain-and-scanning.md](supply-chain-and-scanning.md)) |
