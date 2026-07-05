---
name: cloudflare-ops
description: "Cloudflare Workers + Wrangler edge-platform operations - Workers runtime, bindings, local dev, secrets, deploy/CI, Pages-vs-Workers, observability. Use for: cloudflare, workers, wrangler, cloudflare pages, KV, D1, R2, durable objects, queues, hyperdrive, workers ai, vectorize, wrangler.toml, wrangler.jsonc, wrangler deploy, wrangler dev, wrangler secret, bindings, compatibility_date, static assets, edge functions, cron triggers, tail workers, gradual deployments."
license: MIT
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
  related-skills: "terraform-ops, nginx-ops"
when_to_use: "Building, configuring, or deploying Cloudflare Workers; writing or fixing wrangler config; choosing or wiring a binding (KV/D1/R2/DO/Queues/Hyperdrive/AI/Vectorize); deciding Workers vs Pages; setting up local dev, secrets, or CI/CD for the edge; debugging deploy errors, CPU limits, or bundling."
---

# Cloudflare Operations

Cloudflare Workers + Wrangler: runtime patterns, bindings, local dev, secrets, deploy, CI/CD, observability.

> Ecosystem facts verified as of 2026-07.

**Version context (verified 2026-07):** Wrangler **v4.x** · config is **`wrangler.jsonc`** (Cloudflare's recommended format for new projects — some newer features are JSON-config-only; `wrangler.toml` still works and is widespread in older repos) · deploy command is **`wrangler deploy`** (the old **`wrangler publish` is deprecated** — see [gotchas](#common-gotchas)). Workers can now **serve static assets**, which is the current direction for full-stack and static sites over Pages (see [Workers vs Pages](#workers-vs-pages-decision)).

## Reference Files

| File | Covers |
|------|--------|
| [references/bindings.md](references/bindings.md) | Every binding (KV/D1/R2/DO/Queues/Hyperdrive/AI/Vectorize/Service/Analytics Engine) — config block, runtime API, when to reach for each, consistency model |
| [references/workers-runtime.md](references/workers-runtime.md) | Runtime APIs, handlers (fetch/scheduled/queue/email/tail), CORS, caching, streaming, WebSockets, Durable Objects deep-dive, limits |
| [references/deploy-and-cicd.md](references/deploy-and-cicd.md) | `wrangler deploy`, environments, secrets, Workers Builds, GitHub Actions + OIDC/API-token, gradual deployments, rollbacks, observability |
| [assets/wrangler.jsonc.template](assets/wrangler.jsonc.template) | Commented, current `wrangler.jsonc` covering all common bindings + assets |

## Workers vs Pages Decision

Cloudflare added static-asset hosting to Workers; a single Worker now serves a static site, a full-stack app, or an API + SPA. **For new projects, default to Workers with static assets.** Pages still works and isn't deprecated, but Workers has the broader, faster-moving feature set (Durable Objects, Cron Triggers, Queues, richer observability) and is where Cloudflare's investment goes.

```
New project?
│
├─ Pure static site (no server logic)
│  └─ Workers + assets binding (asset-only — requests matching files never invoke Worker code, $0 for those).
│     Pages is also fine here; Workers keeps one platform if you later add logic.
│
├─ Full-stack / SPA + API / SSR framework (Next, Astro, Remix, SvelteKit, Hono)
│  └─ Workers + assets + a Worker script. Use the framework's Cloudflare adapter (C3: `npm create cloudflare@latest`).
│     This is the current recommended path — Pages' framework story is converging into Workers.
│
├─ Already on Pages and happy
│  └─ Stay. "What works in Pages works in Workers" — migrate only when you need a Workers-only
│     feature (DO, Cron, Queues, advanced observability). See the migrate-from-pages guide.
│
└─ Need Durable Objects / Cron Triggers / Queues / Tail Workers
   └─ Workers (these are Workers-only).
```

**Asset serving modes** (in the `assets` block): asset-only (no `main`) serves files directly and never bills Worker invocations for matches; **assets + Worker** serves matching files first, falls through to your `fetch` handler for everything else (or set `run_worker_first` to invoke the Worker before asset matching). Reach assets from code via `env.ASSETS.fetch(request)`.

## Wrangler Config Skeleton (jsonc)

Full annotated version: [assets/wrangler.jsonc.template](assets/wrangler.jsonc.template).

```jsonc
{
  "$schema": "node_modules/wrangler/config-schema.json",
  "name": "my-worker",
  "main": "src/index.ts",
  "compatibility_date": "2026-06-01",   // pins the runtime version — REQUIRED, bump deliberately
  "compatibility_flags": ["nodejs_compat"],  // opt-in runtime features (Node built-ins, etc.)

  "observability": { "enabled": true },  // turn on Workers Logs (off by default)

  "assets": { "directory": "./public", "binding": "ASSETS" },

  "kv_namespaces": [{ "binding": "CACHE", "id": "<kv-id>" }],
  "d1_databases": [{ "binding": "DB", "database_name": "app", "database_id": "<d1-id>" }],
  "r2_buckets":   [{ "binding": "BUCKET", "bucket_name": "uploads" }],

  "vars": { "ENVIRONMENT": "production" },  // NON-secret config only — never put secrets here

  "env": {
    "staging": { "vars": { "ENVIRONMENT": "staging" } }  // named env: deploy with --env staging
  }
}
```

- **`compatibility_date`** = `yyyy-mm-dd`, selects the runtime version. It's required and load-bearing: bumping it can change behaviour, so do it deliberately and test. **`compatibility_flags`** opt into upcoming/Node-compat features (e.g. `nodejs_compat`).
- Keep secrets OUT of `vars` — they land in plaintext in the deployed config. Use `wrangler secret put` / `.dev.vars` ([secrets](#local-dev--secrets)).
- TOML equivalent still parses; the binding shapes map 1:1 (`[[kv_namespaces]]`, `[[d1_databases]]`, …). New repos: prefer jsonc.

## Bindings Table — When Each

Full config + runtime API for every binding: [references/bindings.md](references/bindings.md).

| Binding | Reach for it when… | Consistency / note |
|---------|--------------------|--------------------|
| **KV** | Read-heavy config/cache, infrequent writes, global reads | **Eventually consistent** (~60s propagation). Fast reads, slow-ish writes. Not for "read your own write". |
| **D1** | Relational/SQL data, moderate scale, per-app database | SQLite at the edge. Strong within a DB; read replication is async. Use for app data with joins. |
| **R2** | Object/blob storage, large files, **zero egress fees** | S3-compatible. Replaces S3 for media/backups/assets you serve. |
| **Durable Objects** | **Strong consistency**, coordination, stateful realtime (chat, presence, game rooms, rate limit counters) | Single-threaded per object instance = serialized = consistent. The answer when KV's eventual consistency bites. SQLite-backed storage available. |
| **Queues** | Async/background work, decoupling, batching, retries | Producer binding + consumer Worker. Smooths spikes; guaranteed delivery with retries + DLQ. |
| **Hyperdrive** | Connecting to an **existing external Postgres/MySQL** with pooling + edge caching | Makes a regional DB feel fast from Workers. Needs `nodejs_compat`. |
| **Workers AI** | Run inference (LLM, embeddings, image) on Cloudflare's GPUs | `ai` binding → `env.AI.run(model, ...)`. Pairs with Vectorize for RAG. |
| **Vectorize** | Vector DB for embeddings / semantic search / RAG | `vectorize` binding. Store + query embeddings, often fed by Workers AI. |
| **Service bindings** | Worker-to-Worker RPC without a network hop | Zero-latency internal calls; compose Workers as services. |

Decision shortcut: **need strong consistency or coordination → Durable Objects. Relational queries → D1. Big files → R2. Cheap global cache → KV. Background work → Queues. External SQL DB → Hyperdrive.**

## Minimal Worker

```javascript
export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === "/health") return Response.json({ ok: true });
    return new Response("Hello from the edge");
  },
};
```

`env` carries every binding (`env.DB`, `env.CACHE`, `env.ASSETS`, secrets, vars). `ctx.waitUntil(promise)` runs background work after the response is sent. Workers require **ES module** format (`export default { fetch }`) — the old service-worker `addEventListener("fetch")` format is legacy. Full handler patterns (scheduled/queue/email/tail, CORS, caching, WebSockets, DO): [references/workers-runtime.md](references/workers-runtime.md).

## Local Dev & Secrets

```bash
npm create cloudflare@latest my-app   # C3 scaffolder — picks framework + adapter + wrangler.jsonc
wrangler dev                          # local dev server (Miniflare/workerd) on localhost:8787
wrangler dev --remote                 # run on Cloudflare's edge (real bindings) instead of local sim
wrangler types                        # generate TS types for env from your bindings → worker-configuration.d.ts
```

**Secrets** (never in `vars`):

| Where | Mechanism |
|-------|-----------|
| Local dev | **`.dev.vars`** file (dotenv format, gitignored) — `wrangler dev` loads it as `env.*`. Per-env: `.dev.vars.staging`. |
| Deployed | **`wrangler secret put NAME`** (prompts for value, encrypts it) · `wrangler secret list` · `wrangler secret delete NAME` |
| CI bulk | `wrangler secret bulk secrets.json` |
| Newer | Cloudflare **Secrets Store** bindings (account-level shared secrets) — see deploy reference |

Add `.dev.vars*` to `.gitignore`. `vars` in config = plaintext public config; secrets are encrypted and write-only.

## Deploy & CI/CD

Full detail: [references/deploy-and-cicd.md](references/deploy-and-cicd.md).

```bash
wrangler deploy                  # build + upload + activate (NOT `wrangler publish` — deprecated)
wrangler deploy --env staging    # deploy a named environment
wrangler versions upload         # upload a new version WITHOUT making it live (gradual deploys)
wrangler versions deploy         # split traffic across versions (e.g. 10% new / 90% old)
wrangler rollback                # revert to the previous deployed version
wrangler tail                    # stream live logs from the deployed Worker
```

- **Workers Builds** — Cloudflare's native git-connected CI: push to GitHub/GitLab, Cloudflare builds + deploys. Zero-config for simple Workers; the default for most teams.
- **GitHub Actions** — `cloudflare/wrangler-action`. Authenticate with a scoped **API token** (`CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID` as secrets), least-privilege (Workers Scripts:Edit). Template + workflow in the deploy reference.
- **Gradual deployments** — `versions upload` then `versions deploy` to shift a percentage of traffic; instant `rollback` if metrics regress.

## Observability

- `"observability": { "enabled": true }` in config turns on **Workers Logs** (structured `console.log` capture in the dashboard) — **off by default**, opt in.
- `wrangler tail` for live request log streaming during an incident.
- **Tail Workers** — a Worker that receives execution traces of another Worker (centralised logging/alerting).
- **Analytics Engine** — write custom time-series metrics from a Worker (`env.AE.writeDataPoint(...)`), query via GraphQL/SQL API.

## Common Gotchas

| Gotcha | Detail | Fix |
|--------|--------|-----|
| **`wrangler publish` is gone** | Renamed to `wrangler deploy` (Wrangler v3+). Old tutorials/CI still say `publish`. | Use `wrangler deploy`. Update any `publish` in scripts/CI. |
| **`wrangler.toml` vs `.jsonc`** | Both parse, but newer features are JSON-config-only and Cloudflare recommends jsonc for new projects. | New projects: `wrangler.jsonc`. Migrating: `wrangler.toml` → jsonc is a mechanical 1:1. |
| **Missing `compatibility_date`** | Required; absent or stale date silently pins old runtime behaviour. | Set it; bump deliberately and test — it can change semantics. |
| **CPU time limit** | Default **30s** CPU per invocation (was 10ms/50ms historically; raised). Wall-clock can be longer while awaiting I/O. CPU-bound loops still get killed. | Offload heavy compute; use Queues for long async work; check the limits page for your plan. |
| **Script size limit** | 3 MB (free) / 10 MB (paid) gzipped. | Trim deps, dynamic-import large modules, avoid bundling node-only libs. |
| **KV eventual consistency** | A write isn't globally visible for up to ~60s; not "read your own write". | Use **Durable Objects** when you need strong consistency. |
| **Node built-ins fail** | `fs`, `crypto`, etc. aren't there by default. | `"compatibility_flags": ["nodejs_compat"]` enables a polyfill subset; check what's actually supported. |
| **Secrets in `vars`** | `vars` ships plaintext in the deployed config. | `wrangler secret put` (deployed) / `.dev.vars` (local). |
| **`request`/`response` body read twice** | Streams are single-use. | `request.clone()` before the first read. |
| **Bundling surprises** | Wrangler uses esbuild; some packages assume Node/CommonJS. | Prefer Workers-compatible libs; set `nodejs_compat`; check the build output. |

## Setup

1. Install: `npm install -g wrangler` (or use `npx wrangler` / `npm create cloudflare@latest` to scaffold).
2. Auth: `wrangler login` (OAuth) for local; **API token** for CI.
3. Copy [assets/wrangler.jsonc.template](assets/wrangler.jsonc.template), strip the bindings you don't need, fill in IDs.
4. `wrangler dev` → `wrangler deploy`.

## Staleness verifier

This skill encodes fast-moving facts (Wrangler major line, recommended `compatibility_date`, `wrangler.jsonc` config convention). [`scripts/check-cloudflare-facts.py`](scripts/check-cloudflare-facts.py) guards them against silent drift:

```bash
# Structural (PR CI, no network): every catalogued fact's prose_token is still
# named in this skill's prose (incl. the jsonc template), and the currency
# note still carries a year.
python scripts/check-cloudflare-facts.py --offline        # exit 0 consistent, 10 drift

# Live (freshness job, never blocks a PR): wrangler still resolves on npm and
# its latest major matches the documented v4.x line.
python scripts/check-cloudflare-facts.py --live            # exit 10 major drift, 7 npm unreachable
```

The canonical fact set lives in [`assets/cloudflare-facts.json`](assets/cloudflare-facts.json); when the Wrangler major, the recommended compatibility_date, or the config convention changes, update it to match or `--offline` fails CI.
