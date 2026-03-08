# Multi-Stage Build Patterns

Language-specific multi-stage Dockerfile patterns for minimal, secure production images.

## Table of Contents

- [Go Multi-Stage Builds](#go-multi-stage-builds)
- [Rust Multi-Stage Builds](#rust-multi-stage-builds)
- [Node.js Multi-Stage Builds](#nodejs-multi-stage-builds)
- [Python Multi-Stage Builds](#python-multi-stage-builds)
- [Builder Pattern with Build Args](#builder-pattern-with-build-args)
- [Cross-Compilation with Buildx](#cross-compilation-with-buildx)

---

## Go Multi-Stage Builds

Go compiles to a static binary, making it ideal for scratch or distroless images.

### Minimal Scratch Image (CGO Disabled)

```dockerfile
# ---- Build Stage ----
FROM golang:1.22-alpine AS builder

WORKDIR /build

# Cache dependencies
COPY go.mod go.sum ./
RUN go mod download

# Build static binary
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags="-s -w -X main.version=1.0.0" \
    -o /app ./cmd/server

# ---- Runtime Stage ----
FROM scratch

# Import CA certificates for HTTPS
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

# Import timezone data
COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo

# Copy binary
COPY --from=builder /app /app

# Run as non-root (numeric UID since scratch has no /etc/passwd)
USER 65534:65534

EXPOSE 8080
ENTRYPOINT ["/app"]
```

**Result:** ~10-15 MB image (vs ~800 MB with full golang image).

### Distroless Alternative (With Debug Shell)

```dockerfile
FROM golang:1.22 AS builder
WORKDIR /build
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /app ./cmd/server

# distroless/static includes CA certs and tzdata
FROM gcr.io/distroless/static:nonroot
COPY --from=builder /app /app
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/app"]
```

**When to use distroless over scratch:**
- Need CA certificates without manually copying them
- Want a non-root user without numeric UID hacks
- Need debug variant (`gcr.io/distroless/static:debug`) for troubleshooting

### Go with CGO Enabled

```dockerfile
FROM golang:1.22 AS builder
WORKDIR /build
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN go build -o /app ./cmd/server

# Need glibc for CGO
FROM gcr.io/distroless/base:nonroot
COPY --from=builder /app /app
USER nonroot:nonroot
ENTRYPOINT ["/app"]
```

---

## Rust Multi-Stage Builds

### With cargo-chef (Optimized Layer Caching)

cargo-chef separates dependency compilation from source compilation, enabling Docker layer caching for Rust dependencies.

```dockerfile
# ---- Chef Stage: Prepare dependency recipe ----
FROM rust:1.77-slim AS chef
RUN cargo install cargo-chef
WORKDIR /build

# ---- Planner Stage: Analyze dependencies ----
FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

# ---- Builder Stage: Build dependencies then source ----
FROM chef AS builder

# Build dependencies (cached unless Cargo.toml/Cargo.lock change)
COPY --from=planner /build/recipe.json recipe.json
RUN cargo chef cook --release --recipe-path recipe.json

# Build application
COPY . .
RUN cargo build --release --bin server

# ---- Runtime Stage ----
FROM gcr.io/distroless/cc:nonroot

COPY --from=builder /build/target/release/server /server

USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/server"]
```

**Why cargo-chef?** Without it, changing any source file recompiles all dependencies (~5-20 min). With cargo-chef, dependency compilation is cached unless `Cargo.toml` or `Cargo.lock` changes.

### Static Musl Build (Scratch Target)

```dockerfile
FROM rust:1.77 AS builder

# Add musl target for static linking
RUN rustup target add x86_64-unknown-linux-musl
RUN apt-get update && apt-get install -y musl-tools && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY src/ ./src/

RUN cargo build --release --target x86_64-unknown-linux-musl

# Fully static binary -> scratch is fine
FROM scratch
COPY --from=builder /build/target/x86_64-unknown-linux-musl/release/server /server
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

USER 65534:65534
ENTRYPOINT ["/server"]
```

---

## Node.js Multi-Stage Builds

### Production Node.js App

```dockerfile
# ---- Build Stage ----
FROM node:20-alpine AS builder

WORKDIR /app

# Install dependencies (cached unless package files change)
COPY package.json package-lock.json ./
RUN npm ci

# Build application (TypeScript, bundler, etc.)
COPY tsconfig.json ./
COPY src/ ./src/
RUN npm run build

# ---- Production Dependencies Stage ----
FROM node:20-alpine AS deps

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

# ---- Runtime Stage ----
FROM node:20-slim

# Install tini for proper signal handling
RUN apt-get update && apt-get install -y --no-install-recommends tini \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Create non-root user
RUN groupadd -r appuser && useradd -r -g appuser appuser

# Copy production dependencies and built code
COPY --from=deps --chown=appuser:appuser /app/node_modules ./node_modules
COPY --from=builder --chown=appuser:appuser /app/dist ./dist
COPY --chown=appuser:appuser package.json ./

USER appuser

ENV NODE_ENV=production
EXPOSE 3000

ENTRYPOINT ["tini", "--"]
CMD ["node", "dist/server.js"]
```

**Key decisions:**
- `npm ci` over `npm install` for reproducible builds
- `--omit=dev` to exclude devDependencies from runtime image
- `tini` to handle PID 1 responsibilities (signal forwarding, zombie reaping)
- `node:20-slim` over alpine to avoid musl compatibility issues with native modules

### Next.js Standalone Build

```dockerfile
FROM node:20-alpine AS builder
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY . .

# next.config.js must have: output: 'standalone'
RUN npm run build

FROM node:20-alpine
WORKDIR /app

RUN addgroup -S appuser && adduser -S -G appuser appuser

# Copy only the standalone output
COPY --from=builder --chown=appuser:appuser /app/.next/standalone ./
COPY --from=builder --chown=appuser:appuser /app/.next/static ./.next/static
COPY --from=builder --chown=appuser:appuser /app/public ./public

USER appuser

ENV NODE_ENV=production
ENV HOSTNAME=0.0.0.0
EXPOSE 3000

CMD ["node", "server.js"]
```

---

## Python Multi-Stage Builds

### With uv (Fast Dependency Management)

```dockerfile
# ---- Build Stage ----
FROM python:3.12-slim AS builder

# Install uv
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

WORKDIR /app

# Install dependencies into a virtual env (cached layer)
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

# Copy application source
COPY src/ ./src/
COPY pyproject.toml ./
RUN uv sync --frozen --no-dev

# ---- Runtime Stage ----
FROM python:3.12-slim

WORKDIR /app

# Create non-root user
RUN groupadd -r appuser && useradd -r -g appuser -d /app appuser

# Copy virtual environment from builder
COPY --from=builder --chown=appuser:appuser /app/.venv /app/.venv
COPY --from=builder --chown=appuser:appuser /app/src ./src

# Ensure venv binaries are on PATH
ENV PATH="/app/.venv/bin:$PATH"
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1

USER appuser

EXPOSE 8000
CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

### With pip (Traditional)

```dockerfile
FROM python:3.12-slim AS builder

WORKDIR /app

# Create virtual environment
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

FROM python:3.12-slim

WORKDIR /app

RUN groupadd -r appuser && useradd -r -g appuser -d /app appuser

# Copy only the virtual environment
COPY --from=builder --chown=appuser:appuser /opt/venv /opt/venv
COPY --chown=appuser:appuser src/ ./src/

ENV PATH="/opt/venv/bin:$PATH"
ENV PYTHONUNBUFFERED=1

USER appuser

EXPOSE 8000
CMD ["gunicorn", "src.main:app", "-w", "4", "-b", "0.0.0.0:8000"]
```

---

## Builder Pattern with Build Args

Use `ARG` to parameterize builds without baking values into the final image.

```dockerfile
# Build-time arguments
ARG GO_VERSION=1.22
ARG APP_VERSION=dev

FROM golang:${GO_VERSION}-alpine AS builder

ARG APP_VERSION
WORKDIR /build
COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-s -w -X main.version=${APP_VERSION}" \
    -o /app ./cmd/server

FROM scratch
COPY --from=builder /app /app
ENTRYPOINT ["/app"]
```

```bash
# Pass args at build time
docker build --build-arg APP_VERSION=1.2.3 --build-arg GO_VERSION=1.23 -t myapp .
```

**Important:** `ARG` values before `FROM` are only available in `FROM` lines. Redeclare `ARG` after `FROM` to use in `RUN` commands.

---

## Cross-Compilation with Buildx

Build images for multiple platforms (amd64, arm64) from a single machine.

### Setup

```bash
# Create a builder instance with multi-platform support
docker buildx create --name multiarch --driver docker-container --use
docker buildx inspect --bootstrap
```

### Cross-Platform Dockerfile

```dockerfile
# BUILDPLATFORM = host platform (where build runs)
# TARGETPLATFORM = target platform (where image runs)
FROM --platform=$BUILDPLATFORM golang:1.22-alpine AS builder

ARG TARGETOS
ARG TARGETARCH

WORKDIR /build
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -ldflags="-s -w" -o /app ./cmd/server

FROM --platform=$TARGETPLATFORM gcr.io/distroless/static:nonroot
COPY --from=builder /app /app
USER nonroot:nonroot
ENTRYPOINT ["/app"]
```

### Build and Push

```bash
# Build for multiple platforms and push to registry
docker buildx build \
    --platform linux/amd64,linux/arm64 \
    -t myregistry/myapp:1.0 \
    --push .

# Build for local use (single platform)
docker buildx build \
    --platform linux/arm64 \
    -t myapp:1.0 \
    --load .
```

### Platform Variables Reference

| Variable | Example Value | Available In |
|----------|--------------|--------------|
| `BUILDPLATFORM` | `linux/amd64` | `FROM --platform=` |
| `TARGETPLATFORM` | `linux/arm64` | `FROM --platform=` |
| `BUILDOS` | `linux` | `RUN` (after ARG) |
| `BUILDARCH` | `amd64` | `RUN` (after ARG) |
| `TARGETOS` | `linux` | `RUN` (after ARG) |
| `TARGETARCH` | `arm64` | `RUN` (after ARG) |
