# Docker Compose Patterns

Production-ready Docker Compose patterns for multi-service applications.

## Table of Contents

- [Service Definitions](#service-definitions)
- [Environment Variables](#environment-variables)
- [Volume Patterns](#volume-patterns)
- [Networking](#networking)
- [Health Checks](#health-checks)
- [Dependency Management](#dependency-management)
- [Override Files](#override-files)
- [Profiles for Optional Services](#profiles-for-optional-services)
- [Docker Compose Watch](#docker-compose-watch)
- [Development vs Production](#development-vs-production)
- [Full Application Example](#full-application-example)

---

## Service Definitions

### Build from Dockerfile

```yaml
services:
  web:
    build:
      context: .
      dockerfile: Dockerfile
      target: production          # Multi-stage build target
      args:
        APP_VERSION: "1.2.3"      # Build-time args
    image: myapp:latest           # Tag the built image
    container_name: myapp-web     # Fixed container name
    restart: unless-stopped
```

### Use Pre-Built Image

```yaml
services:
  db:
    image: postgres:16-alpine
    restart: unless-stopped
```

### Resource Limits

```yaml
services:
  worker:
    image: myapp-worker:latest
    deploy:
      resources:
        limits:
          cpus: "2.0"
          memory: 512M
        reservations:
          cpus: "0.5"
          memory: 128M
```

---

## Environment Variables

### Inline

```yaml
services:
  web:
    environment:
      NODE_ENV: production
      DATABASE_URL: postgres://user:pass@db:5432/myapp
      REDIS_URL: redis://cache:6379
```

### From File

```yaml
services:
  web:
    env_file:
      - .env                     # Default variables
      - .env.production          # Override for production
```

### Variable Interpolation

```yaml
# Uses host environment variables or .env file in project root
services:
  web:
    image: myapp:${APP_VERSION:-latest}
    environment:
      DB_HOST: ${DB_HOST:?DB_HOST must be set}    # Fail if not set
      LOG_LEVEL: ${LOG_LEVEL:-info}                # Default to "info"
```

### Precedence (highest to lowest)

1. `docker compose run -e` or `docker compose exec -e`
2. `environment:` in compose file
3. `--env-file` CLI flag
4. `env_file:` in compose file
5. `.env` file in project directory
6. Host environment variables

---

## Volume Patterns

### Named Volumes (Persistent Data)

```yaml
services:
  db:
    image: postgres:16-alpine
    volumes:
      - db-data:/var/lib/postgresql/data    # Docker-managed volume

volumes:
  db-data:
    driver: local
```

### Bind Mounts (Development)

```yaml
services:
  web:
    volumes:
      - ./src:/app/src:cached          # Source code (cached for macOS perf)
      - ./config:/app/config:ro        # Config files (read-only)
```

### tmpfs (In-Memory, Ephemeral)

```yaml
services:
  web:
    tmpfs:
      - /tmp                            # Writable temp directory
      - /app/cache:size=100M            # Capped in-memory cache
    read_only: true                     # Read-only root filesystem
```

### Anonymous Volumes (Protect Container Paths)

```yaml
services:
  web:
    volumes:
      - ./src:/app/src                  # Override source
      - /app/node_modules              # But keep container's node_modules
```

---

## Networking

### Custom Networks

```yaml
services:
  web:
    networks:
      - frontend
      - backend

  api:
    networks:
      - backend

  db:
    networks:
      - backend                        # db is NOT accessible from frontend

networks:
  frontend:
    driver: bridge
  backend:
    driver: bridge
    internal: true                     # No external access
```

### Service Discovery

Services on the same network can reach each other by service name:

```yaml
services:
  web:
    environment:
      API_URL: http://api:3000         # "api" resolves to the api container
      DB_HOST: db                      # "db" resolves to the db container

  api:
    # ...

  db:
    # ...
```

### Port Mapping

```yaml
services:
  web:
    ports:
      - "8080:3000"                    # host:container
      - "127.0.0.1:9090:9090"         # Bind to localhost only
      - "3000"                         # Random host port -> container 3000
```

### Static IPs (When Needed)

```yaml
services:
  dns:
    networks:
      backend:
        ipv4_address: 172.20.0.10

networks:
  backend:
    ipam:
      config:
        - subnet: 172.20.0.0/24
```

---

## Health Checks

### HTTP Health Check

```yaml
services:
  web:
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s                # Grace period for startup
```

### TCP Health Check (No curl Available)

```yaml
services:
  web:
    healthcheck:
      test: ["CMD-SHELL", "nc -z localhost 3000 || exit 1"]
      interval: 15s
      timeout: 3s
      retries: 3
```

### Database Health Checks

```yaml
services:
  postgres:
    image: postgres:16-alpine
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5

  mysql:
    image: mysql:8
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 3s
      retries: 5
```

---

## Dependency Management

### depends_on with Health Conditions

```yaml
services:
  web:
    depends_on:
      db:
        condition: service_healthy     # Wait for db to pass healthcheck
      cache:
        condition: service_healthy
      migrations:
        condition: service_completed_successfully  # Run-once service

  migrations:
    build: .
    command: ["python", "manage.py", "migrate"]
    depends_on:
      db:
        condition: service_healthy

  db:
    image: postgres:16-alpine
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 3s
      retries: 10

  cache:
    image: redis:7-alpine
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5
```

**Important:** Without `condition: service_healthy`, `depends_on` only waits for the container to start, not for the service inside to be ready.

---

## Override Files

Docker Compose automatically merges `docker-compose.yml` with `docker-compose.override.yml`.

### Base: docker-compose.yml

```yaml
services:
  web:
    build: .
    ports:
      - "3000:3000"
    environment:
      NODE_ENV: production

  db:
    image: postgres:16-alpine
    volumes:
      - db-data:/var/lib/postgresql/data

volumes:
  db-data:
```

### Development Override: docker-compose.override.yml

```yaml
# Automatically merged with docker-compose.yml
services:
  web:
    build:
      target: development
    volumes:
      - ./src:/app/src                 # Live reload
      - /app/node_modules
    environment:
      NODE_ENV: development
      DEBUG: "true"
    ports:
      - "9229:9229"                    # Node debugger

  db:
    ports:
      - "5432:5432"                    # Expose DB port for local tools
    environment:
      POSTGRES_PASSWORD: devpass
```

### Production Override: docker-compose.prod.yml

```yaml
services:
  web:
    build:
      target: production
    restart: always
    deploy:
      replicas: 2
      resources:
        limits:
          memory: 512M

  db:
    restart: always
    # No port exposure in production
```

### Using Override Files

```bash
# Development (auto-merges override.yml)
docker compose up

# Production (explicit file selection)
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d

# Testing
docker compose -f docker-compose.yml -f docker-compose.test.yml run --rm test
```

---

## Profiles for Optional Services

Profiles let you define services that only start when explicitly requested.

```yaml
services:
  web:
    build: .
    ports:
      - "3000:3000"
    # No profile = always starts

  db:
    image: postgres:16-alpine
    # No profile = always starts

  adminer:
    image: adminer
    ports:
      - "8080:8080"
    profiles:
      - debug                         # Only starts with --profile debug

  mailhog:
    image: mailhog/mailhog
    ports:
      - "1025:1025"
      - "8025:8025"
    profiles:
      - debug                         # Only starts with --profile debug

  prometheus:
    image: prom/prometheus
    profiles:
      - monitoring                     # Only starts with --profile monitoring

  grafana:
    image: grafana/grafana
    profiles:
      - monitoring
```

```bash
# Start core services only
docker compose up

# Start with debug tools
docker compose --profile debug up

# Start with monitoring
docker compose --profile monitoring up

# Start with everything
docker compose --profile debug --profile monitoring up
```

---

## Docker Compose Watch

Live reload for development without bind mounts (Compose 2.22+).

```yaml
services:
  web:
    build:
      context: .
      target: development
    develop:
      watch:
        # Sync source files -> restart not needed (hot reload)
        - action: sync
          path: ./src
          target: /app/src

        # Rebuild when dependencies change
        - action: rebuild
          path: ./package.json

        # Sync + restart when config changes
        - action: sync+restart
          path: ./config
          target: /app/config

        # Ignore patterns
          ignore:
            - "**/*.test.ts"
            - "**/node_modules"
```

```bash
# Start with file watching
docker compose watch

# Or alongside up
docker compose up --watch
```

### Watch Actions

| Action | Behavior | Use Case |
|--------|----------|----------|
| `sync` | Copy changed files into container | Source code with HMR/hot reload |
| `rebuild` | Rebuild and recreate the container | Dependency changes (package.json) |
| `sync+restart` | Copy files then restart container | Config files, non-HMR code |

---

## Development vs Production

### Development Compose

```yaml
# docker-compose.yml (development-focused)
services:
  web:
    build:
      context: .
      target: development
    volumes:
      - ./src:/app/src
    ports:
      - "3000:3000"
      - "9229:9229"              # Debugger
    environment:
      NODE_ENV: development
    command: ["npm", "run", "dev"]

  db:
    image: postgres:16-alpine
    ports:
      - "5432:5432"              # Exposed for local access
    environment:
      POSTGRES_PASSWORD: devpass
      POSTGRES_DB: myapp_dev
    volumes:
      - db-data:/var/lib/postgresql/data
      - ./db/seed.sql:/docker-entrypoint-initdb.d/seed.sql

volumes:
  db-data:
```

### Production Compose

```yaml
# docker-compose.prod.yml
services:
  web:
    image: myregistry/myapp:${VERSION}    # Pre-built image
    restart: always
    read_only: true
    tmpfs:
      - /tmp
    ports:
      - "3000:3000"
    environment:
      NODE_ENV: production
    deploy:
      replicas: 2
      resources:
        limits:
          memory: 512M
          cpus: "1.0"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
      interval: 30s
      retries: 3
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  db:
    image: postgres:16-alpine
    restart: always
    # NO port exposure
    environment:
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
    secrets:
      - db_password
    volumes:
      - db-data:/var/lib/postgresql/data

secrets:
  db_password:
    file: ./secrets/db_password.txt

volumes:
  db-data:
```

---

## Full Application Example

Web app + API + database + cache + worker + reverse proxy.

```yaml
services:
  # ---- Reverse Proxy ----
  nginx:
    image: nginx:1.25-alpine
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./nginx/certs:/etc/nginx/certs:ro
    depends_on:
      web:
        condition: service_healthy
    networks:
      - frontend
    restart: unless-stopped

  # ---- Web Application ----
  web:
    build:
      context: .
      target: production
    environment:
      DATABASE_URL: postgres://app:${DB_PASSWORD}@db:5432/myapp
      REDIS_URL: redis://cache:6379
      API_URL: http://api:4000
    depends_on:
      db:
        condition: service_healthy
      cache:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
      interval: 30s
      timeout: 5s
      retries: 3
    networks:
      - frontend
      - backend
    restart: unless-stopped

  # ---- API Service ----
  api:
    build:
      context: ./api
      target: production
    environment:
      DATABASE_URL: postgres://app:${DB_PASSWORD}@db:5432/myapp
      REDIS_URL: redis://cache:6379
    depends_on:
      db:
        condition: service_healthy
      cache:
        condition: service_healthy
    networks:
      - backend
    restart: unless-stopped

  # ---- Background Worker ----
  worker:
    build:
      context: .
      target: production
    command: ["node", "dist/worker.js"]
    environment:
      DATABASE_URL: postgres://app:${DB_PASSWORD}@db:5432/myapp
      REDIS_URL: redis://cache:6379
    depends_on:
      db:
        condition: service_healthy
      cache:
        condition: service_healthy
    networks:
      - backend
    restart: unless-stopped
    deploy:
      replicas: 2
      resources:
        limits:
          memory: 256M

  # ---- Database ----
  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: app
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_DB: myapp
    volumes:
      - db-data:/var/lib/postgresql/data
      - ./db/init.sql:/docker-entrypoint-initdb.d/01-init.sql:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U app -d myapp"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - backend
    restart: unless-stopped

  # ---- Cache ----
  cache:
    image: redis:7-alpine
    command: redis-server --maxmemory 128mb --maxmemory-policy allkeys-lru
    volumes:
      - cache-data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 3s
      retries: 5
    networks:
      - backend
    restart: unless-stopped

volumes:
  db-data:
  cache-data:

networks:
  frontend:
    driver: bridge
  backend:
    driver: bridge
    internal: true                     # Backend not accessible externally
```
