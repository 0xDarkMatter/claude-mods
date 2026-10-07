# Compose Patterns

compose.yaml as of Compose v5 (2026). Compose v2.40.3 was the last v2 release. v5 builds
through Bake, and v3 and v4 were skipped to avoid confusion with the old file-format versions.

## Contents

- [File name, validation and the v5 change](#file-name-validation-and-the-v5-change)
- [A service in its safe shape](#a-service-in-its-safe-shape)
- [Environment, interpolation and secrets](#environment-interpolation-and-secrets)
- [Readiness: healthchecks and depends_on](#readiness-healthchecks-and-depends_on)
- [Dev loop: develop.watch](#dev-loop-developwatch)
- [Profiles, include and overrides](#profiles-include-and-overrides)
- [Volumes and data](#volumes-and-data)
- [Networks](#networks)
- [Production hardening](#production-hardening)
- [Common failures](#common-failures)

## File name, validation and the v5 change

- Compose looks for `compose.yaml`, `compose.yml`, `docker-compose.yml`, `docker-compose.yaml`,
  in that order, and warns when more than one exists. New projects use `compose.yaml`.
- A top-level `version:` is ignored with a warning (`the attribute version is obsolete`).
  Delete it.
- Name the project with a top-level `name:`, or Compose derives it from the folder name, and
  two checkouts of the same repo collide.
- **Validate with `docker compose config --quiet`** (it prints nothing and exits non-zero on
  errors). Plain `docker compose config` prints every interpolated value and pastes
  `env_file` contents into `environment:`, which lands your secrets in a terminal, a CI log
  or an agent's context. To read the file without resolving anything, use
  `docker compose config --no-interpolate`.

## A service in its safe shape

```yaml
name: shop
services:
  api:
    build: {context: ., target: runtime}
    image: ghcr.io/acme/shop-api:dev
    pull_policy: build
    ports:
      - "127.0.0.1:8080:8080"
    env_file: [.env.api]                 # gitignored; .env.api.example is committed
    secrets: [stripe_key]
    depends_on:
      db: {condition: service_healthy, restart: true}
    restart: unless-stopped
```

- **`image:` next to `build:` names the build output.** If that name is an unqualified
  Docker Hub name (`image: shop-api`), `docker compose pull` fetches whatever public image
  has that name. Qualify it with a registry, or set `pull_policy: build`.
- **`ports:` publishes to the host; `expose:` doesn't.** Services on the same Compose network
  reach each other by service name on the container port, with no `ports:` at all. Publish
  only what a human or a host process needs, bound to `127.0.0.1`. A datastore usually needs
  no published port.
- Pin every `image:` to a tag (and a digest in production). `docker-audit.py` reports
  `image-untagged`, `image-latest` and `datastore-published`.

## Environment, interpolation and secrets

Two different `.env` mechanisms are easy to confuse:

| Mechanism | What it does |
|---|---|
| `.env` beside compose.yaml | sets variables for **interpolation** (`${VAR}` in the file); not passed into containers by itself |
| `env_file:` | passes each line into the container's environment |
| `environment:` | sets container variables; beats `env_file:` |
| `docker compose run -e` | beats both, for that run |

Interpolation forms: `${VAR}`; `${VAR:-default}` (default when unset or empty);
`${VAR:?message}` (fail with a message when unset or empty, the right form for a required
secret); `$$` for a literal `$`. A literal secret in `environment:` is a committed secret:
`docker-audit.py` flags `compose-literal-secret`, including the literal fallback in
`${VAR:-literal}`.

Secrets mount as files under `/run/secrets/<name>`, which never appear in `docker inspect`:

```yaml
services:
  db:
    image: postgres:18.6-trixie
    environment: {POSTGRES_PASSWORD_FILE: /run/secrets/db_password}
    secrets: [db_password]
secrets:
  db_password: {file: ./secrets/db_password.txt}     # or: environment: DB_PASSWORD
```

Most official images read `<VAR>_FILE`. For your own app, read the file path at startup.

## Readiness: healthchecks and depends_on

```yaml
  db:
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d app"]
      interval: 5s
      timeout: 3s
      retries: 10
      start_period: 20s
      start_interval: 1s
  api:
    depends_on:
      db: {condition: service_healthy, restart: true}
      migrate: {condition: service_completed_successfully}
      cache: {condition: service_started, required: false}
```

- `service_started` (and the list form `depends_on: [db]`) waits for the container to start,
  not for the database to accept connections. Use `service_healthy` for datastores.
- `service_healthy` needs a healthcheck on the dependency (in Compose or in its image), or
  `up` fails with "no healthcheck configured".
- `restart: true` restarts the dependent when the dependency is restarted on purpose (not
  after a crash). `required: false` turns a missing dependency into a warning.
- **Distroless services have no shell and no curl.** Probe with the app's own binary
  (`test: ["CMD", "/app", "healthz"]`), or run a healthcheck sidecar in the service's
  network namespace and make the dependents wait on the sidecar:
  ```yaml
    api-health:
      image: curlimages/curl:8.17.0
      network_mode: "service:api"
      command: ["sleep", "infinity"]
      healthcheck: {test: ["CMD", "curl", "-fsS", "http://localhost:8080/healthz"], interval: 5s}
  ```

## Dev loop: develop.watch

`develop.watch` (GA since Compose 2.22) syncs files into a running container, or rebuilds
it, without the cost of a bind mount (slow on macOS and Windows file sharing):

```yaml
  web:
    build: .
    develop:
      watch:
        - {action: sync, path: ./src, target: /app/src, ignore: [node_modules/]}
        - {action: sync+restart, path: ./config, target: /app/config}
        - {action: rebuild, path: package-lock.json}
```

Actions are `sync`, `rebuild`, `sync+restart`, `restart` and `sync+exec` (the last two need
Compose 2.32+, and `sync+exec` takes an `exec:` block). `.dockerignore` applies implicitly.
Run it with `docker compose watch` or `docker compose up --watch`.

## Profiles, include and overrides

- **Profiles** keep optional services out of a plain `up`: `profiles: [debug]`, then
  `docker compose --profile debug up`. A service with no profile always starts.
- **`compose.override.yaml`** merges automatically onto `compose.yaml`. Pass `-f` explicitly
  (`-f compose.yaml -f compose.prod.yaml`) to choose the set instead. Maps merge key by key,
  and most lists append.
- **`!reset`** clears an inherited value (`ports: !reset []`); **`!override`** replaces it
  outright instead of merging.
- **`include:`** pulls another project's Compose file in with its own relative paths: the
  way to compose stacks from separate repos without copy-paste.

## Volumes and data

- Named volumes (`dbdata:/var/lib/postgresql`) are managed by the engine and survive
  `down`. Bind mounts (`./data:/data`) are host folders: slow under Docker Desktop's file
  sharing, and owned by whatever UID the container writes as.
- **PostgreSQL 18 images keep data under `/var/lib/postgresql/18/docker`** and declare the
  volume at `/var/lib/postgresql`. Mount the volume there. An old `/var/lib/postgresql/data`
  mount from a 16 or 17 stack does not carry the data across a major upgrade; use
  `pg_upgrade` or a dump and restore.
- `docker compose down -v` deletes the project's named volumes. That is Tier 2: name them
  and confirm first ([destructive-commands.md](destructive-commands.md)).
- Back up a volume before anything risky:
  `docker run --rm -v shop_dbdata:/v:ro -v "$PWD":/b alpine:3.22 tar czf /b/dbdata.tgz -C /v .`

## Networks

- Each project gets a default network; services resolve each other by service name.
- `internal: true` on a network cuts it off from the outside: use it for backends.
- To reach the host from a container: `host.docker.internal`. Docker Desktop, OrbStack and
  Colima provide it. On a native Linux engine, add
  `extra_hosts: ["host.docker.internal:host-gateway"]`.
- Subnet clashes with a VPN, and ports that won't bind: [ports-and-networking.md](ports-and-networking.md).

## Production hardening

`docker-audit.py --production` checks these per service:

```yaml
    read_only: true
    tmpfs: [/tmp]
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    user: "10001:10001"
    deploy: {resources: {limits: {memory: 512m, cpus: "1.0"}}}
    restart: unless-stopped
    logging: {driver: local, options: {max-size: 10m}}
```

Docker Desktop 4.94 made `local` the default log driver for new Linux containers. On other
engines the default `json-file` grows without bound unless `max-size` is set.

## Common failures

| Symptom | Cause | Fix |
|---|---|---|
| `port is already allocated` | another container or host process holds it | `docker-doctor.py --ports N` names the holder |
| `forbidden by its access permissions` (Windows) | a port Windows has reserved | [ports-and-networking.md](ports-and-networking.md) |
| app can't reach `db` at start | `depends_on` without `service_healthy` | add a healthcheck and the condition |
| `dependency failed to start ... no healthcheck` | `service_healthy` on a service without one | add the healthcheck |
| a service starts that you didn't want | it has no `profiles:` | give it a profile |
| changes in `src/` don't show up | no watch or bind mount; or a stale image | `docker compose watch`, or `up --build` |
| data gone after `down` | `down -v`, or an anonymous volume | named volumes; never `-v` without a backup |
