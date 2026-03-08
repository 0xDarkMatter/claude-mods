# Go Project Structure Reference

## Table of Contents

1. [Standard Project Layout](#standard-project-layout)
2. [Module Management](#module-management)
3. [Workspace Mode](#workspace-mode)
4. [Build Tags](#build-tags)
5. [Build Configuration](#build-configuration)
6. [Makefile and Justfile Patterns](#makefile-and-justfile-patterns)
7. [Linting](#linting)
8. [Code Generation](#code-generation)
9. [Release](#release)

---

## Standard Project Layout

The Go community has converged on a layout that separates public, private, and executable code clearly.

```
myapp/
├── cmd/                    # Executable entry points (one dir per binary)
│   ├── server/
│   │   └── main.go
│   └── worker/
│       └── main.go
├── internal/               # Private packages (import-restricted by go toolchain)
│   ├── config/
│   │   └── config.go
│   ├── handler/
│   │   └── user.go
│   ├── service/
│   │   └── user.go
│   └── repository/
│       └── user.go
├── pkg/                    # Public packages (importable by external projects)
│   └── validator/
│       └── validator.go
├── api/                    # API definitions (OpenAPI, protobuf, gRPC)
│   └── openapi.yaml
├── web/                    # Web assets, templates
├── scripts/                # Build, install, CI scripts
├── configs/                # Config file templates
├── testdata/               # Test fixtures (go tools ignore dirs starting with "testdata")
├── go.mod
├── go.sum
├── Makefile (or justfile)
└── README.md
```

### When to Use Each Directory

**cmd/**: Place `main.go` files here. Each subdirectory is a separate binary. Keep main.go thin — parse flags, load config, wire dependencies, then call into `internal/`.

**internal/**: Use for everything application-specific. The Go toolchain enforces that packages under `internal/` can only be imported by code in the parent directory tree. Use this for business logic, handlers, database access.

**pkg/**: Only create this if you genuinely want external projects to import your code. Most applications do not need `pkg/` at all. Avoid the anti-pattern of putting everything in `pkg/` just to follow the template.

```go
// cmd/server/main.go — wire dependencies here, logic lives in internal/
func main() {
    cfg, err := config.Load()
    if err != nil {
        log.Fatalf("loading config: %v", err)
    }

    db, err := database.Connect(cfg.DatabaseURL)
    if err != nil {
        log.Fatalf("connecting to database: %v", err)
    }

    repo := repository.NewUser(db)
    svc := service.NewUser(repo)
    h := handler.NewUser(svc)

    srv := &http.Server{Addr: cfg.Addr, Handler: h.Routes()}
    log.Fatal(srv.ListenAndServe())
}
```

---

## Module Management

### go.mod Directives

```
module github.com/myorg/myapp

go 1.22

require (
    github.com/lib/pq v1.10.9
    golang.org/x/sync v0.6.0
)

// Replace a dependency with a local version during development
replace github.com/myorg/shared => ../shared

// Exclude a specific broken version
exclude github.com/bad/module v1.2.3
```

**require**: Direct and indirect dependencies. The `// indirect` comment marks transitive dependencies that aren't directly imported by your code but are required by your dependencies.

**replace**: Use for local development of shared modules, or to patch a dependency without forking. Remove before merging to main — `replace` directives break downstream consumers.

**exclude**: Prevents a specific version from being selected by MVS. Useful when a version has a known bug and you want to force a later version.

### Manage go.sum

`go.sum` contains the expected cryptographic checksums of module content. Commit it to version control. Never edit it manually. Regenerate with:

```bash
go mod tidy        # Add missing, remove unused dependencies
go mod verify      # Verify checksums against go.sum
go mod download    # Pre-download modules (useful in Docker layers)
```

### Private Modules

Configure the Go toolchain to skip the public checksum database and proxy for private code:

```bash
# Tell go to bypass proxy and sumdb for private modules
export GOPRIVATE=github.com/myorg/*

# Separate controls for proxy and sumdb
export GONOSUMCHECK=github.com/myorg/*
export GONOPROXY=github.com/myorg/*

# Use a corporate proxy for public modules
export GOPROXY=https://proxy.company.com,direct
```

In CI, set these as environment variables. For `.netrc`-based auth with private GitHub:

```
machine github.com login git password <personal-access-token>
```

---

## Workspace Mode

Workspaces allow multiple modules to be developed together without `replace` directives.

```bash
go work init ./app ./shared ./tools   # Creates go.work
go work use ./new-module              # Add another module
go work sync                          # Sync dependencies
```

**go.work file:**

```
go 1.22

use (
    ./app
    ./shared
    ./tools
)
```

### When Workspaces Help

- Developing two modules simultaneously (e.g., a library and a consuming app)
- Monorepo with multiple Go modules
- Testing unreleased changes to a shared package before publishing

### When Workspaces Do Not Help

- Single-module repos (no benefit)
- Production builds — exclude `go.work` from Docker contexts with `.dockerignore`

```
# .dockerignore
go.work
go.work.sum
```

---

## Build Tags

Build tags control which files are included in a build. The modern syntax uses `//go:build`.

```go
//go:build integration

package mypackage
```

```go
//go:build linux && amd64

package mypackage
```

```go
//go:build !windows

package mypackage
```

### Common Tag Patterns

```go
//go:build ignore          // Exclude from normal builds (e.g., generation scripts)

//go:build integration     // Integration tests requiring real external services

//go:build e2e             // End-to-end tests

//go:build cgo             // Only build when CGO is enabled
```

### Run Builds with Tags

```bash
go test -tags integration ./...
go build -tags production ./cmd/server
go vet -tags integration ./...
```

### Separate Integration Tests

```go
//go:build integration

package repository_test

import (
    "testing"
    "os"
)

func TestUserRepository_Integration(t *testing.T) {
    dsn := os.Getenv("TEST_DATABASE_URL")
    if dsn == "" {
        t.Skip("TEST_DATABASE_URL not set")
    }
    // ... test against real database
}
```

---

## Build Configuration

### Inject Version Information at Build Time

```go
// internal/version/version.go
package version

var (
    Version   = "dev"
    GitCommit = "unknown"
    BuildDate = "unknown"
)
```

```bash
go build \
  -ldflags="-X github.com/myorg/myapp/internal/version.Version=1.2.3 \
             -X github.com/myorg/myapp/internal/version.GitCommit=$(git rev-parse --short HEAD) \
             -X github.com/myorg/myapp/internal/version.BuildDate=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  ./cmd/server
```

### Build Static Binaries

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
  -ldflags="-s -w" \
  -trimpath \
  -o bin/server \
  ./cmd/server
```

- `CGO_ENABLED=0`: Disable cgo, produce a statically linked binary
- `-s -w`: Strip debug info and DWARF symbols (reduces binary size ~30%)
- `-trimpath`: Remove local file paths from the binary (reproducible builds, avoids leaking local paths)

### Cross-Compile

```bash
GOOS=windows GOARCH=amd64 go build ./cmd/server
GOOS=darwin  GOARCH=arm64 go build ./cmd/server
GOOS=linux   GOARCH=arm64 go build ./cmd/server
```

---

## Makefile and Justfile Patterns

### Makefile

```makefile
BINARY     := bin/server
VERSION    := $(shell git describe --tags --always --dirty)
COMMIT     := $(shell git rev-parse --short HEAD)
BUILD_DATE := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
LDFLAGS    := -X main.version=$(VERSION) -X main.commit=$(COMMIT)

.PHONY: build test lint generate clean docker

build:
	CGO_ENABLED=0 go build -ldflags="$(LDFLAGS)" -trimpath -o $(BINARY) ./cmd/server

test:
	go test -race -coverprofile=coverage.out ./...
	go tool cover -html=coverage.out -o coverage.html

test-integration:
	go test -race -tags integration ./...

lint:
	golangci-lint run ./...

generate:
	go generate ./...

clean:
	rm -rf bin/ coverage.out coverage.html

docker:
	docker build --build-arg VERSION=$(VERSION) -t myapp:$(VERSION) .

tidy:
	go mod tidy
	go mod verify
```

### Justfile

```just
version := `git describe --tags --always --dirty`
commit  := `git rev-parse --short HEAD`

build:
    CGO_ENABLED=0 go build \
        -ldflags="-X main.version={{version}} -X main.commit={{commit}}" \
        -trimpath -o bin/server ./cmd/server

test:
    go test -race -coverprofile=coverage.out ./...

test-integration:
    go test -race -tags integration ./...

lint:
    golangci-lint run ./...

generate:
    go generate ./...

tidy:
    go mod tidy && go mod verify
```

---

## Linting

### Install and Run golangci-lint

```bash
# Install (do not use go install — use the official installer)
curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh \
  | sh -s -- -b $(go env GOPATH)/bin v1.57.2

golangci-lint run ./...
golangci-lint run --fix ./...    # Auto-fix where possible
```

### Recommended .golangci.yml

```yaml
linters:
  enable:
    - errcheck        # Check all error returns are handled
    - gosimple        # Simplification suggestions
    - govet           # go vet checks
    - ineffassign     # Detect unused variable assignments
    - staticcheck     # Comprehensive static analysis
    - unused          # Detect unused code
    - gofmt           # Enforce gofmt formatting
    - goimports       # Enforce import grouping
    - gocritic        # Opinionated style checks
    - misspell        # Catch common misspellings
    - prealloc        # Suggest slice pre-allocation
    - exhaustive      # Enforce exhaustive enum switches
    - noctx           # Detect HTTP requests without context

linters-settings:
  errcheck:
    check-blank: true
  govet:
    enable-all: true
  gocritic:
    enabled-tags: [diagnostic, style, performance]

issues:
  exclude-rules:
    - path: _test\.go
      linters: [errcheck]   # Relax error checking in tests
```

### Suppress Specific Warnings

```go
//nolint:errcheck  // Intentionally ignoring close error on best-effort cleanup
defer f.Close()

//nolint:exhaustive  // Default case handles unrecognized values
switch status {
case Active:
    return "active"
default:
    return "unknown"
}
```

---

## Code Generation

### go generate

Place `//go:generate` directives in the file where the generated output belongs conceptually.

```go
// internal/domain/status.go
//go:generate stringer -type=Status

type Status int

const (
    Active Status = iota
    Inactive
    Pending
)
```

```go
// internal/repository/mock_store.go (or a dedicated mocks/ dir)
//go:generate mockgen -source=store.go -destination=mock_store.go -package=repository
```

Run all generators:

```bash
go generate ./...
```

### Embed Static Files

```go
import "embed"

//go:embed templates/*.html
var templateFS embed.FS

//go:embed migrations
var migrationsFS embed.FS

//go:embed static/app.js static/app.css
var staticFiles embed.FS
```

- Paths are relative to the file containing the directive
- Supports glob patterns and directories
- Embedded files are read-only at runtime

---

## Release

### goreleaser

```yaml
# .goreleaser.yml
project_name: myapp

builds:
  - id: server
    main: ./cmd/server
    binary: server
    env:
      - CGO_ENABLED=0
    goos: [linux, darwin, windows]
    goarch: [amd64, arm64]
    ldflags:
      - -s -w
      - -X main.version={{.Version}}
      - -X main.commit={{.Commit}}
      - -X main.date={{.Date}}
    flags:
      - -trimpath

archives:
  - format: tar.gz
    format_overrides:
      - goos: windows
        format: zip

checksum:
  name_template: "checksums.txt"

changelog:
  sort: asc
  filters:
    exclude: ['^docs:', '^test:', Merge pull request]
```

```bash
# Dry run to verify configuration
goreleaser release --snapshot --clean

# Publish a real release (requires GITHUB_TOKEN)
goreleaser release --clean
```

### Manual Cross-Compile Script

```bash
#!/usr/bin/env bash
set -euo pipefail

VERSION=$(git describe --tags --always)
PLATFORMS=("linux/amd64" "linux/arm64" "darwin/amd64" "darwin/arm64" "windows/amd64")

for platform in "${PLATFORMS[@]}"; do
    GOOS="${platform%/*}"
    GOARCH="${platform#*/}"
    output="dist/server_${GOOS}_${GOARCH}"
    [[ "$GOOS" == "windows" ]] && output="${output}.exe"

    echo "Building $output"
    CGO_ENABLED=0 GOOS="$GOOS" GOARCH="$GOARCH" go build \
        -ldflags="-s -w -X main.version=${VERSION}" \
        -trimpath -o "$output" ./cmd/server
done
```
