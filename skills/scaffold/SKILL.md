---
name: scaffold
description: "Project scaffolding - generate boilerplate for common project types with best-practice defaults. Use for: scaffold, boilerplate, template, new project, init, create project, starter, setup, project structure, directory structure, monorepo, microservice, API template, web app template, CLI tool template, library template."
license: MIT
allowed-tools: "Read Edit Write Bash Glob Grep Agent"
metadata:
  author: claude-mods
  related-skills: docker-ops, ci-cd-ops, testing-ops, python-env, typescript-ops
---

# Scaffold

Project scaffolding templates and boilerplate generation for common project types with best-practice defaults.

## Project Type Decision Tree

```
What are you building?
│
├─ API / Backend Service
│  ├─ REST API
│  │  ├─ Python → FastAPI (async, OpenAPI auto-docs)
│  │  ├─ Node.js → Express or Fastify (Fastify for performance)
│  │  ├─ Go → Gin (ergonomic) or Echo (middleware-rich)
│  │  └─ Rust → Axum (tower ecosystem, async-first)
│  ├─ GraphQL API
│  │  ├─ Python → Strawberry + FastAPI
│  │  ├─ Node.js → Apollo Server or Pothos + Yoga
│  │  ├─ Go → gqlgen (code-first)
│  │  └─ Rust → async-graphql + Axum
│  └─ gRPC Service
│     ├─ Python → grpcio + protobuf
│     ├─ Go → google.golang.org/grpc
│     └─ Rust → tonic
│
├─ Web Application
│  ├─ Full-stack with SSR
│  │  ├─ React ecosystem → Next.js 14+ (App Router)
│  │  ├─ Vue ecosystem → Nuxt 3
│  │  ├─ Svelte ecosystem → SvelteKit
│  │  └─ Content-heavy / multi-framework → Astro
│  ├─ SPA (client-only)
│  │  ├─ React → Vite + React + React Router
│  │  ├─ Vue → Vite + Vue + Vue Router
│  │  └─ Svelte → Vite + Svelte + svelte-routing
│  └─ Static Site
│     ├─ Blog / docs → Astro or VitePress
│     └─ Marketing / landing → Astro or Next.js (static export)
│
├─ CLI Tool
│  ├─ Python → Typer (simple) or Click (complex)
│  ├─ Node.js → Commander + Inquirer
│  ├─ Go → Cobra + Viper
│  └─ Rust → Clap (derive API)
│
├─ Library / Package
│  ├─ npm package → TypeScript + tsup + Vitest
│  ├─ PyPI package → uv + pyproject.toml + pytest
│  ├─ Go module → go mod init + go test
│  └─ Rust crate → cargo init --lib + cargo test
│
└─ Monorepo
   ├─ JavaScript/TypeScript → Turborepo + pnpm workspaces
   ├─ Full-stack JS → Nx
   ├─ Go → Go workspaces (go.work)
   ├─ Rust → Cargo workspaces
   └─ Python → uv workspaces or hatch
```

## Stack Selection Matrix

| Project Type | Language | Framework | Database | ORM/Query | Deploy Target |
|-------------|----------|-----------|----------|-----------|---------------|
| REST API | Python | FastAPI | PostgreSQL | SQLAlchemy + Alembic | Docker / AWS ECS |
| REST API | Node.js | Fastify | PostgreSQL | Prisma or Drizzle | Docker / Vercel |
| REST API | Go | Gin | PostgreSQL | sqlx (raw) or GORM | Docker / Fly.io |
| REST API | Rust | Axum | PostgreSQL | sqlx | Docker / Fly.io |
| Web App | TypeScript | Next.js 14+ | PostgreSQL | Prisma or Drizzle | Vercel / Docker |
| Web App | TypeScript | Nuxt 3 | PostgreSQL | Prisma | Vercel / Netlify |
| Web App | TypeScript | Astro | SQLite / none | Drizzle | Cloudflare / Netlify |
| CLI Tool | Python | Typer | SQLite | sqlite3 stdlib | PyPI |
| CLI Tool | Go | Cobra | SQLite / BoltDB | sqlx | GitHub Releases |
| CLI Tool | Rust | Clap | SQLite | rusqlite | crates.io |
| Library | TypeScript | tsup | n/a | n/a | npm |
| Library | Python | hatch/uv | n/a | n/a | PyPI |

## Quick Scaffold Commands

### Python (API)

```bash
# FastAPI with uv
mkdir my-api && cd my-api
uv init --python 3.12
uv add fastapi uvicorn sqlalchemy alembic psycopg2-binary pydantic-settings
uv add --dev pytest pytest-asyncio httpx ruff mypy
```

### Node.js (Web App)

```bash
# Next.js 14+
npx create-next-app@latest my-app --typescript --tailwind --eslint --app --src-dir --import-alias "@/*"

# Vite + React
npm create vite@latest my-app -- --template react-ts
```

### Go (API)

```bash
mkdir my-api && cd my-api
go mod init github.com/user/my-api
go get github.com/gin-gonic/gin
go get github.com/jmoiron/sqlx
go get github.com/lib/pq
```

### Rust (CLI)

```bash
cargo init my-cli
cd my-cli
cargo add clap --features derive
cargo add serde --features derive
cargo add anyhow tokio --features tokio/full
```

### Monorepo (Turborepo)

```bash
npx create-turbo@latest my-monorepo
# Or manual:
mkdir my-monorepo && cd my-monorepo
npm init -y
npm install turbo --save-dev
mkdir -p apps/web apps/api packages/shared
```

## API Project Template

### Directory Structure (FastAPI Example)

```
my-api/
├── src/
│   └── my_api/
│       ├── __init__.py
│       ├── main.py              # FastAPI app, lifespan, middleware
│       ├── config.py            # pydantic-settings configuration
│       ├── database.py          # SQLAlchemy engine, session
│       ├── dependencies.py      # Shared FastAPI dependencies
│       ├── routers/
│       │   ├── __init__.py
│       │   ├── health.py        # Health check endpoint
│       │   └── users.py         # User CRUD endpoints
│       ├── models/
│       │   ├── __init__.py
│       │   └── user.py          # SQLAlchemy models
│       ├── schemas/
│       │   ├── __init__.py
│       │   └── user.py          # Pydantic request/response schemas
│       └── services/
│           ├── __init__.py
│           └── user.py          # Business logic
├── alembic/
│   ├── alembic.ini
│   ├── env.py
│   └── versions/
├── tests/
│   ├── conftest.py              # Fixtures: test DB, client, factories
│   ├── test_health.py
│   └── test_users.py
├── pyproject.toml
├── Dockerfile
├── docker-compose.yml
├── .env.example
├── .gitignore
└── .dockerignore
```

### Directory Structure (Express/Fastify Example)

```
my-api/
├── src/
│   ├── index.ts                 # Entry point, server startup
│   ├── app.ts                   # Express/Fastify app setup
│   ├── config.ts                # Environment config with zod validation
│   ├── database.ts              # Prisma client or Drizzle config
│   ├── middleware/
│   │   ├── auth.ts
│   │   ├── error-handler.ts
│   │   └── request-logger.ts
│   ├── routes/
│   │   ├── health.ts
│   │   └── users.ts
│   ├── services/
│   │   └── user.service.ts
│   └── types/
│       └── index.ts
├── prisma/
│   └── schema.prisma
├── tests/
│   ├── setup.ts
│   └── routes/
│       └── users.test.ts
├── package.json
├── tsconfig.json
├── Dockerfile
├── docker-compose.yml
├── .env.example
└── .gitignore
```

## Web App Project Template

### Directory Structure (Next.js App Router)

```
my-app/
├── src/
│   ├── app/
│   │   ├── layout.tsx           # Root layout
│   │   ├── page.tsx             # Home page
│   │   ├── loading.tsx          # Global loading UI
│   │   ├── error.tsx            # Global error boundary
│   │   ├── not-found.tsx        # 404 page
│   │   ├── globals.css          # Global styles + Tailwind
│   │   ├── (auth)/
│   │   │   ├── login/page.tsx
│   │   │   └── register/page.tsx
│   │   ├── dashboard/
│   │   │   ├── layout.tsx
│   │   │   └── page.tsx
│   │   └── api/
│   │       └── health/route.ts
│   ├── components/
│   │   ├── ui/                  # Reusable primitives
│   │   └── features/            # Feature-specific components
│   ├── lib/
│   │   ├── db.ts                # Database client
│   │   ├── auth.ts              # Auth helpers
│   │   └── utils.ts             # Shared utilities
│   └── types/
│       └── index.ts
├── public/
│   └── favicon.ico
├── tests/
│   ├── setup.ts
│   └── components/
├── next.config.ts
├── tailwind.config.ts
├── tsconfig.json
├── package.json
├── .env.local.example
└── .gitignore
```

## CLI Tool Project Template

### Directory Structure (Python / Typer)

```
my-cli/
├── src/
│   └── my_cli/
│       ├── __init__.py
│       ├── __main__.py          # python -m my_cli entry
│       ├── cli.py               # Typer app, command groups
│       ├── commands/
│       │   ├── __init__.py
│       │   ├── init.py          # my-cli init
│       │   └── run.py           # my-cli run
│       ├── config.py            # Config file loading (TOML/YAML)
│       └── utils.py
├── tests/
│   ├── conftest.py
│   └── test_commands.py
├── pyproject.toml               # [project.scripts] entry point
├── .gitignore
└── README.md
```

### Directory Structure (Go / Cobra)

```
my-cli/
├── cmd/
│   ├── root.go                  # Root command, global flags
│   ├── init.go                  # my-cli init
│   └── run.go                   # my-cli run
├── internal/
│   ├── config/
│   │   └── config.go            # Viper config loading
│   └── runner/
│       └── runner.go            # Core logic
├── main.go                      # Entry point, calls cmd.Execute()
├── go.mod
├── go.sum
├── Makefile
└── .gitignore
```

## Library Project Template

### Directory Structure (npm Package)

```
my-lib/
├── src/
│   ├── index.ts                 # Public API exports
│   ├── core.ts                  # Core implementation
│   └── types.ts                 # Public type definitions
├── tests/
│   └── core.test.ts
├── package.json                 # "type": "module", exports map
├── tsconfig.json                # declaration: true, declarationMap: true
├── tsup.config.ts               # Build config: cjs + esm
├── vitest.config.ts
├── .npmignore
├── .gitignore
├── CHANGELOG.md
└── LICENSE
```

### Directory Structure (PyPI Package)

```
my-lib/
├── src/
│   └── my_lib/
│       ├── __init__.py          # Public API, __version__
│       ├── core.py
│       └── py.typed             # PEP 561 marker
├── tests/
│   ├── conftest.py
│   └── test_core.py
├── pyproject.toml               # Build system, metadata, tool config
├── .gitignore
├── CHANGELOG.md
└── LICENSE
```

## Monorepo Template

### Turborepo + pnpm Workspaces

```
my-monorepo/
├── apps/
│   ├── web/                     # Next.js frontend
│   │   ├── src/
│   │   ├── package.json         # depends on @repo/shared
│   │   └── tsconfig.json        # extends ../../tsconfig.base.json
│   └── api/                     # Fastify backend
│       ├── src/
│       ├── package.json
│       └── tsconfig.json
├── packages/
│   ├── shared/                  # Shared types, utils, validators
│   │   ├── src/
│   │   ├── package.json         # "name": "@repo/shared"
│   │   └── tsconfig.json
│   ├── ui/                      # Shared React components
│   │   ├── src/
│   │   └── package.json         # "name": "@repo/ui"
│   └── config/                  # Shared configs
│       ├── eslint/
│       ├── typescript/
│       └── package.json
├── turbo.json                   # Pipeline: build, test, lint
├── pnpm-workspace.yaml          # packages: ["apps/*", "packages/*"]
├── package.json                 # Root devDeps: turbo
├── tsconfig.base.json           # Shared TypeScript config
├── .gitignore
└── .npmrc
```

### Cargo Workspaces (Rust)

```
my-workspace/
├── crates/
│   ├── my-core/                 # Core library
│   │   ├── src/lib.rs
│   │   └── Cargo.toml
│   ├── my-cli/                  # CLI binary
│   │   ├── src/main.rs
│   │   └── Cargo.toml           # depends on my-core
│   └── my-server/               # API binary
│       ├── src/main.rs
│       └── Cargo.toml
├── Cargo.toml                   # [workspace] members = ["crates/*"]
├── Cargo.lock
├── .gitignore
└── rust-toolchain.toml
```

## Common Additions Checklist

```
Project setup complete? Add these:
│
├─ Version Control
│  ├─ [ ] .gitignore (language-specific)
│  ├─ [ ] .gitattributes (line endings, binary files)
│  └─ [ ] Branch protection rules
│
├─ CI/CD
│  ├─ [ ] GitHub Actions workflow (test on PR, deploy on merge)
│  ├─ [ ] Matrix testing (OS, runtime versions)
│  └─ [ ] Release automation
│
├─ Docker
│  ├─ [ ] Multi-stage Dockerfile
│  ├─ [ ] docker-compose.yml (app + database + cache)
│  ├─ [ ] .dockerignore
│  └─ [ ] Health check endpoint
│
├─ Code Quality
│  ├─ [ ] Linter (ESLint, Ruff, golangci-lint, Clippy)
│  ├─ [ ] Formatter (Prettier, Black/Ruff, gofmt, rustfmt)
│  ├─ [ ] Pre-commit hooks (Husky, pre-commit)
│  └─ [ ] Type checking (TypeScript strict, mypy, go vet)
│
├─ Testing
│  ├─ [ ] Test framework configured (Vitest, pytest, go test)
│  ├─ [ ] Coverage reporting
│  ├─ [ ] Test database setup
│  └─ [ ] CI test pipeline
│
├─ Editor
│  ├─ [ ] .editorconfig
│  ├─ [ ] .vscode/settings.json
│  └─ [ ] .vscode/extensions.json
│
└─ Documentation
   ├─ [ ] README.md (project description, setup, usage)
   ├─ [ ] CONTRIBUTING.md
   └─ [ ] API documentation (OpenAPI, godoc, rustdoc)
```

## Configuration File Templates

### .editorconfig (Universal)

```ini
root = true

[*]
indent_style = space
indent_size = 2
end_of_line = lf
charset = utf-8
trim_trailing_whitespace = true
insert_final_newline = true

[*.{py,rs}]
indent_size = 4

[*.go]
indent_style = tab

[*.md]
trim_trailing_whitespace = false

[Makefile]
indent_style = tab
```

### pyproject.toml (Python)

```toml
[project]
name = "my-project"
version = "0.1.0"
requires-python = ">=3.12"

[tool.ruff]
target-version = "py312"
line-length = 88

[tool.ruff.lint]
select = ["E", "F", "I", "UP", "B", "SIM"]

[tool.pytest.ini_options]
testpaths = ["tests"]
asyncio_mode = "auto"

[tool.mypy]
strict = true
```

### tsconfig.json (TypeScript - Strict)

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "resolveJsonModule": true,
    "declaration": true,
    "declarationMap": true,
    "sourceMap": true,
    "outDir": "./dist",
    "rootDir": "./src"
  },
  "include": ["src"],
  "exclude": ["node_modules", "dist"]
}
```

## Common Gotchas

| Gotcha | Why It Happens | Prevention |
|--------|---------------|------------|
| Wrong .gitignore for language | Used generic template, missing language-specific entries | Use `gitignore.io` or GitHub's templates for your stack |
| Forgot .env.example | Team members don't know which env vars are needed | Create .env.example with every var (empty values) at project start |
| No lockfile committed | Inconsistent dependency versions across environments | Commit package-lock.json, uv.lock, go.sum, Cargo.lock |
| Hardcoded port/host in code | Works locally, breaks in Docker/cloud | Always read from env var with sensible default |
| Tests coupled to real database | Tests fail without running DB, CI setup is complex | Use test containers or in-memory SQLite for unit tests |
| Missing health check endpoint | Deployment orchestrator cannot verify readiness | Add /health endpoint that checks DB connectivity |
| No multi-stage Docker build | Image is 2GB instead of 200MB | Use builder stage for deps/compile, slim runtime stage |
| Mixing tabs and spaces | .editorconfig missing, editor defaults vary | Add .editorconfig to every project root |
| No .dockerignore | Docker context sends node_modules/venv, build takes minutes | Mirror .gitignore entries plus .git directory |
| Monorepo without workspace protocol | Packages resolve from registry instead of local | Use `workspace:*` (pnpm) or path deps (Cargo, Go) |
| TypeScript paths not in tsconfig | Module aliases work in dev but fail at build time | Configure paths in tsconfig AND build tool (tsup, vite) |

## Reference Files

| File | Contents | Lines |
|------|----------|-------|
| `references/api-templates.md` | Complete API scaffolds: FastAPI, Express/Fastify, Gin, Axum with full file content | ~700 |
| `references/frontend-templates.md` | Web app scaffolds: Next.js, Nuxt 3, Astro, SvelteKit, Vite+React with config | ~650 |
| `references/tooling-templates.md` | CI/CD, Docker, linting, testing, pre-commit, editor config, git templates | ~550 |

## See Also

| Skill | When to Combine |
|-------|----------------|
| `docker-ops` | Container configuration, multi-stage builds, compose orchestration |
| `ci-cd-ops` | GitHub Actions workflows, deployment pipelines, release automation |
| `testing-ops` | Test framework setup, coverage configuration, CI test integration |
| `python-env` | Python virtual environments, dependency management with uv |
| `typescript-ops` | TypeScript configuration, strict mode, module resolution |
