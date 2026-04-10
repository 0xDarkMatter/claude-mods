---
name: docker-ops
description: "Docker containerization patterns, Dockerfile best practices, multi-stage builds, and Docker Compose. Use for: docker, Dockerfile, docker-compose, container, image, multi-stage build, docker build, docker run, .dockerignore, health check, distroless, scratch image, BuildKit, layer caching, container security."
license: MIT
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
  related-skills: container-orchestration, go-ops, rust-ops, ci-cd-ops
---

# Docker Operations

Comprehensive Docker patterns for building, running, and composing containerized applications.

## Dockerfile Best Practices

| Practice | Do | Don't |
|----------|------|-------|
| Base image | `FROM node:20-slim` | `FROM node:latest` |
| Layer caching | Copy dependency files first, then source | `COPY . .` before `RUN install` |
| Package install | `apt-get update && apt-get install -y ... && rm -rf /var/lib/apt/lists/*` | Separate `RUN` for update and install |
| User | `USER nonroot` (create if needed) | Run as root in production |
| Multi-stage | Separate build and runtime stages | Ship compiler toolchains |
| Secrets | `--mount=type=secret` (BuildKit) | `COPY .env .` or `ARG PASSWORD` |
| ENTRYPOINT vs CMD | `ENTRYPOINT` for fixed binary, `CMD` for defaults | Relying on shell form for signal handling |
| WORKDIR | `WORKDIR /app` | `RUN cd /app && ...` |
| .dockerignore | Include `.git`, `node_modules`, `__pycache__` | No .dockerignore at all |
| Labels | `LABEL org.opencontainers.image.*` | No metadata |

## Multi-Stage Build Decision Tree

Choose your runtime base image by language:

```
Go ──────────── CGO disabled? ──── Yes ──► scratch or distroless/static
                                   No ───► distroless/base or alpine

Rust ─────────── Static musl? ──── Yes ──► scratch or distroless/static
                                   No ───► distroless/cc or debian-slim

Node.js ──────── Need native? ──── Yes ──► node:20-slim
                                   No ───► node:20-alpine (smaller)

Python ────────── Need C libs? ─── Yes ──► python:3.12-slim
                                   No ───► python:3.12-slim (still slim)

Java ──────────── JRE only ──────────────► eclipse-temurin:21-jre-alpine
```

> **See:** `references/multi-stage-builds.md` for complete annotated examples per language.

## Layer Caching Rules

Docker caches each layer. A cache miss at layer N invalidates all subsequent layers.

### What Invalidates Cache

| Trigger | Effect |
|---------|--------|
| Changed file in `COPY`/`ADD` | Invalidates this layer + all below |
| Changed `RUN` command text | Invalidates this layer + all below |
| Changed `ARG` value | Invalidates from the `ARG` declaration down |
| `--no-cache` flag | Invalidates everything |
| Base image update | Invalidates everything |

### Optimal Layer Order

```dockerfile
# 1. Base image (changes rarely)
FROM python:3.12-slim

# 2. System dependencies (changes rarely)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# 3. Dependency files (changes occasionally)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 4. Application code (changes frequently)
COPY src/ ./src/

# 5. Runtime config (changes frequently)
CMD ["python", "-m", "app"]
```

**Rule of thumb:** Order layers from least-frequently-changed to most-frequently-changed.

## .dockerignore Essentials

```dockerignore
# Version control
.git
.gitignore

# Dependencies (rebuilt in container)
node_modules
__pycache__
*.pyc
.venv
vendor/

# Build artifacts
dist/
build/
target/
*.egg-info

# IDE and editor
.vscode
.idea
*.swp
*.swo

# Docker files (prevent recursive context)
Dockerfile*
docker-compose*
.dockerignore

# Environment and secrets
.env
.env.*
*.pem
*.key

# Documentation and tests (unless needed)
docs/
tests/
*.md
LICENSE
```

**Why it matters:** Without `.dockerignore`, `docker build` sends the entire context directory to the daemon. A `.git` folder alone can add hundreds of megabytes.

## Docker Compose Quick Reference

### Service Definition

```yaml
services:
  web:
    build:
      context: .
      dockerfile: Dockerfile
      target: production        # Multi-stage target
    image: myapp:latest
    ports:
      - "8080:8000"
    environment:
      DATABASE_URL: postgres://db:5432/app
    env_file:
      - .env
    volumes:
      - ./src:/app/src          # Bind mount (dev)
      - app-data:/app/data      # Named volume (persistent)
    depends_on:
      db:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
    restart: unless-stopped
    networks:
      - backend
```

### Volumes and Networks

```yaml
volumes:
  app-data:           # Named volume (Docker-managed)
  db-data:
    driver: local

networks:
  backend:
    driver: bridge
  frontend:
    driver: bridge
```

> **See:** `references/compose-patterns.md` for full patterns including profiles, watch mode, and override files.

## Security Quick Reference

| Area | Recommendation |
|------|----------------|
| User | Run as non-root: `RUN adduser -D appuser && USER appuser` |
| Base image | Pin digest: `FROM python:3.12-slim@sha256:abc123...` |
| Filesystem | Read-only root: `docker run --read-only --tmpfs /tmp` |
| Capabilities | Drop all, add needed: `--cap-drop=ALL --cap-add=NET_BIND_SERVICE` |
| Secrets | BuildKit secrets: `RUN --mount=type=secret,id=key cat /run/secrets/key` |
| Scanning | Scan images: `trivy image myapp:latest` or `grype myapp:latest` |
| No latest | Always use specific tags and pin versions |
| Minimal image | Use distroless or scratch when possible |
| No SUID | `RUN find / -perm /6000 -type f -exec chmod a-s {} +` |
| Network | Use internal networks for backend services |

### Non-Root User Pattern

```dockerfile
# Debian/Ubuntu-based
RUN groupadd -r appuser && useradd -r -g appuser -d /app -s /sbin/nologin appuser
COPY --chown=appuser:appuser . /app
USER appuser

# Alpine-based
RUN addgroup -S appuser && adduser -S -G appuser appuser
COPY --chown=appuser:appuser . /app
USER appuser

# Distroless (built-in nonroot user)
FROM gcr.io/distroless/static:nonroot
USER nonroot:nonroot
```

## Common Gotchas

| Gotcha | Problem | Fix |
|--------|---------|-----|
| Large images | Shipping build tools, node_modules in final image | Multi-stage builds |
| Cache busting | `COPY . .` before `RUN npm install` | Copy lockfile first, install, then copy source |
| Secrets in layers | `COPY .env .` or `ARG SECRET=...` bakes secrets into image history | Use `--mount=type=secret` or runtime env vars |
| PID 1 problem | App doesn't receive SIGTERM, zombie processes | Use `tini` as init or `exec` form for CMD |
| Timezone | Container uses UTC | Set `TZ` env var or install `tzdata` |
| DNS caching | Alpine musl DNS issues | Use `RUN apk add --no-cache libc6-compat` or switch to slim |
| apt cache | `apt-get update` cached from old layer | Always combine `update && install` in one RUN |
| Missing signals | Shell form (`CMD npm start`) wraps in `/bin/sh` | Exec form: `CMD ["node", "server.js"]` |
| Build context size | Sending GB of data to daemon | Add `.dockerignore`, check with `docker build --progress=plain` |
| Layer explosion | Each RUN creates a layer | Chain related commands with `&&` |

### PID 1 / Signal Handling Fix

```dockerfile
# Option 1: Use tini as init process
RUN apt-get update && apt-get install -y --no-install-recommends tini \
    && rm -rf /var/lib/apt/lists/*
ENTRYPOINT ["tini", "--"]
CMD ["node", "server.js"]

# Option 2: Docker init flag (Docker 23.0+)
# docker run --init myapp

# Option 3: Node.js - handle signals in code
# process.on('SIGTERM', () => { server.close(); process.exit(0); });
```

## Essential Docker Commands

```bash
# Build
docker build -t myapp:1.0 .
docker build -t myapp:1.0 --target production .    # Multi-stage target
docker build --no-cache -t myapp:1.0 .              # Force rebuild

# Run
docker run -d --name myapp -p 8080:8000 myapp:1.0
docker run --rm -it myapp:1.0 /bin/sh               # Interactive debug
docker run --read-only --tmpfs /tmp myapp:1.0        # Read-only root

# Inspect
docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"
docker history myapp:1.0                             # Layer breakdown
docker inspect myapp:1.0 | jq '.[0].Config'         # Image config

# Debug running container
docker exec -it myapp /bin/sh
docker logs -f myapp
docker stats myapp

# Cleanup
docker system prune -a --volumes                     # Remove everything unused
docker image prune -a                                # Remove unused images
```

## Reference Files

| File | Contents |
|------|----------|
| `references/multi-stage-builds.md` | Per-language multi-stage patterns (Go, Rust, Node, Python) |
| `references/compose-patterns.md` | Compose services, networking, profiles, watch, overrides |
| `references/optimization.md` | Image size, BuildKit, security scanning, debugging |
