# Docker Optimization

Image size reduction, BuildKit features, security scanning, and debugging techniques.

## Table of Contents

- [Base Image Selection](#base-image-selection)
- [Layer Ordering Strategy](#layer-ordering-strategy)
- [BuildKit Features](#buildkit-features)
- [.dockerignore Patterns](#dockerignore-patterns)
- [Multi-Platform Builds](#multi-platform-builds)
- [Security Scanning](#security-scanning)
- [Health Checks and Graceful Shutdown](#health-checks-and-graceful-shutdown)
- [Container Resource Limits](#container-resource-limits)
- [Logging Best Practices](#logging-best-practices)
- [Debug Techniques](#debug-techniques)

---

## Base Image Selection

| Image Type | Size | Use Case | Security |
|------------|------|----------|----------|
| `scratch` | 0 MB | Go/Rust static binaries | Minimal attack surface |
| `distroless/static` | ~2 MB | Static binaries + CA certs | No shell, no package manager |
| `distroless/base` | ~20 MB | Dynamic binaries (CGO) | No shell |
| `distroless/cc` | ~25 MB | Rust/C++ with libgcc | No shell |
| `alpine` | ~7 MB | Small general-purpose | Musl libc (compatibility issues) |
| `*-slim` | ~80 MB | Python, Node, Java | Glibc, minimal packages |
| `*:latest` | 200-900 MB | Development only | Full package set, large surface |

### Decision Guide

```
Need shell for debugging?
├── No  → distroless or scratch
└── Yes → alpine or slim

Using Go/Rust with static linking?
├── Yes → scratch (smallest) or distroless/static (has CA certs)
└── No  → distroless/base or slim

Using Python/Node?
├── Need native C extensions? → slim (glibc)
└── Pure Python/JS?          → slim (still recommended) or alpine
```

### Size Comparison (Real-World Go App)

```
golang:1.22          ~820 MB
golang:1.22-alpine   ~260 MB
distroless/static     ~12 MB   (with app binary)
scratch                ~8 MB   (with app binary)
```

---

## Layer Ordering Strategy

### Principle: Least-Changed First

```dockerfile
# Layer 1: Base (changes ~yearly)
FROM python:3.12-slim

# Layer 2: System packages (changes ~monthly)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq-dev curl \
    && rm -rf /var/lib/apt/lists/*

# Layer 3: Dependencies (changes ~weekly)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Layer 4: Application code (changes ~daily)
COPY src/ ./src/

# Layer 5: Runtime config (changes ~daily)
CMD ["python", "-m", "app"]
```

### Anti-Pattern: Cache-Busting Copy

```dockerfile
# BAD: Any source change invalidates npm install cache
COPY . .
RUN npm install
RUN npm run build

# GOOD: Install deps first, then copy source
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build
```

### Combining RUN Commands

```dockerfile
# BAD: 3 layers, apt cache persists in first layer
RUN apt-get update
RUN apt-get install -y curl
RUN rm -rf /var/lib/apt/lists/*

# GOOD: 1 layer, no residual cache
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
```

---

## BuildKit Features

Enable BuildKit (default in Docker 23.0+):

```bash
export DOCKER_BUILDKIT=1
# Or use docker buildx build
```

### Cache Mounts

Persist package manager caches across builds without bloating the image.

```dockerfile
# apt cache mount
RUN --mount=type=cache,target=/var/cache/apt \
    --mount=type=cache,target=/var/lib/apt \
    apt-get update && apt-get install -y libpq-dev

# pip cache mount
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install -r requirements.txt

# npm cache mount
RUN --mount=type=cache,target=/root/.npm \
    npm ci

# Go module cache mount
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go build -o /app .

# Cargo cache mount (Rust)
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/app/target \
    cargo build --release
```

### Secret Mounts

Pass secrets during build without persisting in image layers.

```dockerfile
# Dockerfile
RUN --mount=type=secret,id=github_token \
    GITHUB_TOKEN=$(cat /run/secrets/github_token) \
    npm install --registry https://npm.pkg.github.com

RUN --mount=type=secret,id=pip_conf,target=/etc/pip.conf \
    pip install -r requirements.txt
```

```bash
# Build command
docker build --secret id=github_token,src=./github_token.txt -t myapp .
docker build --secret id=pip_conf,src=./pip.conf -t myapp .
```

### SSH Mounts

Forward SSH agent for private repository access during build.

```dockerfile
RUN --mount=type=ssh \
    git clone git@github.com:private/repo.git /app/deps
```

```bash
docker build --ssh default -t myapp .
```

### Heredoc Syntax (BuildKit)

Multi-line scripts and inline files without escaping.

```dockerfile
# syntax=docker/dockerfile:1

# Multi-line script
RUN <<EOF
apt-get update
apt-get install -y curl jq
rm -rf /var/lib/apt/lists/*
EOF

# Inline file creation
COPY <<EOF /app/config.json
{
  "port": 3000,
  "log_level": "info"
}
EOF

# Inline script with different interpreter
RUN <<'PYTHON'
#!/usr/bin/env python3
import json
config = {"version": "1.0"}
with open("/app/version.json", "w") as f:
    json.dump(config, f)
PYTHON
```

---

## .dockerignore Patterns

### Comprehensive .dockerignore

```dockerignore
# Version control
.git
.gitignore
.gitmodules

# CI/CD
.github
.gitlab-ci.yml
.circleci
Jenkinsfile

# Docker (prevent recursive context)
Dockerfile*
docker-compose*
.dockerignore

# Dependencies (rebuilt in container)
node_modules
.venv
__pycache__
*.pyc
vendor/
target/

# Build artifacts
dist/
build/
*.egg-info
*.whl

# IDE
.vscode
.idea
*.swp
*.swo
.DS_Store
Thumbs.db

# Environment and secrets
.env
.env.*
*.pem
*.key
*.crt
secrets/

# Documentation (unless needed at runtime)
docs/
*.md
LICENSE
CHANGELOG

# Tests (unless needed at runtime)
tests/
test/
*_test.go
*.test.js
*.spec.ts
coverage/
.nyc_output
```

### Measuring Build Context

```bash
# See what Docker sends to the daemon
docker build --progress=plain . 2>&1 | grep "transferring context"

# List what would be sent (approximation)
tar -czf - --exclude-from=.dockerignore . | wc -c
```

---

## Multi-Platform Builds

### Setup Buildx

```bash
# Create builder with multi-platform support
docker buildx create --name multiarch --driver docker-container --use
docker buildx inspect --bootstrap

# List available platforms
docker buildx ls
```

### Build for Multiple Platforms

```bash
# Build and push multi-arch manifest
docker buildx build \
    --platform linux/amd64,linux/arm64 \
    -t myregistry/myapp:1.0 \
    --push .

# Build for local use (single platform only with --load)
docker buildx build \
    --platform linux/arm64 \
    -t myapp:local \
    --load .

# Build and export to tarball
docker buildx build \
    --platform linux/amd64,linux/arm64 \
    -t myapp:1.0 \
    --output type=oci,dest=myapp.tar .
```

### QEMU for Cross-Architecture

```bash
# Install QEMU user-mode emulation
docker run --privileged --rm tonistiigi/binfmt --install all

# Verify
docker buildx ls
# Should show: linux/amd64, linux/arm64, linux/arm/v7, etc.
```

---

## Security Scanning

### Trivy (Recommended)

```bash
# Scan image for vulnerabilities
trivy image myapp:latest

# Scan with severity filter
trivy image --severity HIGH,CRITICAL myapp:latest

# Scan Dockerfile for misconfigurations
trivy config Dockerfile

# Scan and fail CI if critical vulns found
trivy image --exit-code 1 --severity CRITICAL myapp:latest

# JSON output for processing
trivy image --format json --output results.json myapp:latest
```

### Grype

```bash
# Scan image
grype myapp:latest

# Only critical and high
grype myapp:latest --only-fixed --fail-on high
```

### Docker Scout (Built-in)

```bash
# Quick vulnerability overview
docker scout quickview myapp:latest

# Detailed CVE list
docker scout cves myapp:latest

# Compare two images
docker scout compare myapp:1.0 myapp:1.1

# Recommendations
docker scout recommendations myapp:latest
```

### CI Integration Example

```yaml
# GitHub Actions
- name: Scan image
  uses: aquasecurity/trivy-action@master
  with:
    image-ref: myapp:${{ github.sha }}
    severity: HIGH,CRITICAL
    exit-code: 1
```

---

## Health Checks and Graceful Shutdown

### Dockerfile HEALTHCHECK

```dockerfile
# HTTP check
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=10s \
    CMD curl -f http://localhost:3000/health || exit 1

# TCP check (no curl needed)
HEALTHCHECK --interval=15s --timeout=3s --retries=3 \
    CMD nc -z localhost 3000 || exit 1

# Custom script
COPY healthcheck.sh /usr/local/bin/
HEALTHCHECK --interval=30s CMD ["healthcheck.sh"]
```

### Graceful Shutdown (SIGTERM Handling)

```dockerfile
# Set stop signal (default is SIGTERM)
STOPSIGNAL SIGTERM

# Use tini for proper signal forwarding
RUN apt-get update && apt-get install -y --no-install-recommends tini \
    && rm -rf /var/lib/apt/lists/*
ENTRYPOINT ["tini", "--"]
CMD ["node", "server.js"]
```

**Node.js signal handler:**

```javascript
process.on('SIGTERM', () => {
  console.log('SIGTERM received, shutting down gracefully');
  server.close(() => {
    console.log('Server closed');
    process.exit(0);
  });
  // Force exit after timeout
  setTimeout(() => process.exit(1), 10000);
});
```

**Python signal handler:**

```python
import signal, sys

def shutdown(signum, frame):
    print("Shutting down gracefully...")
    # Close connections, flush buffers
    sys.exit(0)

signal.signal(signal.SIGTERM, shutdown)
```

### Stop Timeout

```bash
# Give container 30s to shut down before SIGKILL
docker stop --time 30 myapp

# In compose
services:
  web:
    stop_grace_period: 30s
```

---

## Container Resource Limits

### Docker Run

```bash
# Memory limit (OOM-killed if exceeded)
docker run --memory=512m --memory-swap=512m myapp

# CPU limit
docker run --cpus=1.5 myapp                    # 1.5 cores
docker run --cpu-shares=512 myapp              # Relative weight

# Combined
docker run --memory=512m --cpus=2 --pids-limit=100 myapp
```

### Docker Compose

```yaml
services:
  web:
    deploy:
      resources:
        limits:
          cpus: "2.0"
          memory: 512M
        reservations:
          cpus: "0.5"
          memory: 128M
```

### Filesystem Limits

```bash
# Read-only root filesystem
docker run --read-only --tmpfs /tmp:size=100M myapp

# Storage driver limit (overlay2)
docker run --storage-opt size=10G myapp
```

---

## Logging Best Practices

### Application: Log to stdout/stderr

```dockerfile
# Redirect app logs to stdout (nginx example)
RUN ln -sf /dev/stdout /var/log/nginx/access.log \
    && ln -sf /dev/stderr /var/log/nginx/error.log
```

### Configure Log Driver

```yaml
# docker-compose.yml
services:
  web:
    logging:
      driver: json-file
      options:
        max-size: "10m"        # Rotate at 10 MB
        max-file: "3"          # Keep 3 rotated files
        compress: "true"
```

### Structured JSON Logging

```bash
# View JSON logs
docker logs myapp --tail 50 | jq .

# Filter by level
docker logs myapp 2>&1 | jq 'select(.level == "error")'
```

---

## Debug Techniques

### Inspect Running Containers

```bash
# Shell into running container
docker exec -it myapp /bin/sh
docker exec -it myapp /bin/bash

# Run command without shell
docker exec myapp cat /app/config.json

# View logs
docker logs myapp                    # All logs
docker logs -f myapp                 # Follow
docker logs --since 5m myapp         # Last 5 minutes
docker logs --tail 100 myapp         # Last 100 lines

# Container stats
docker stats myapp                   # Live CPU/mem/net/disk
docker top myapp                     # Running processes

# Full container details
docker inspect myapp | jq '.[0].State'
docker inspect myapp | jq '.[0].NetworkSettings.Networks'
```

### Debug a Failed Build

```bash
# Build with progress output
docker build --progress=plain -t myapp .

# Target a specific stage
docker build --target builder -t myapp:debug .
docker run -it myapp:debug /bin/sh

# Use build output for debugging
docker build --progress=plain . 2>&1 | tee build.log
```

### Ephemeral Debug Containers

```bash
# Attach a debug container to a running container's network
docker run -it --rm \
    --network container:myapp \
    nicolaka/netshoot \
    curl http://localhost:3000/health

# Debug with full tools
docker run -it --rm \
    --pid container:myapp \
    --network container:myapp \
    nicolaka/netshoot \
    bash
```

### Image Inspection

```bash
# Layer history and sizes
docker history myapp:latest

# Detailed layer analysis with dive
dive myapp:latest

# Export filesystem for inspection
docker save myapp:latest | tar -xf - -C /tmp/image-layers

# Check image config
docker inspect myapp:latest | jq '.[0].Config'

# Compare image sizes
docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" | sort -k3 -h
```

### Compose Debugging

```bash
# View merged config
docker compose config

# View logs for all services
docker compose logs -f

# View logs for specific service
docker compose logs -f web

# Restart single service
docker compose restart web

# Rebuild and restart
docker compose up -d --build web

# Run one-off command
docker compose run --rm web npm test

# View service status
docker compose ps
```
