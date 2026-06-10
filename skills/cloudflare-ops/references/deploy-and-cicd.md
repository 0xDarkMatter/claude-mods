# Deploy, Environments, Secrets, CI/CD, Observability

Verified 2026-06. **The deploy command is `wrangler deploy`. `wrangler publish` is deprecated** (renamed in Wrangler v3; v4 is current) — update any CI/script still calling `publish`.

## Core commands

```bash
wrangler deploy                 # build + upload + activate the Worker
wrangler deploy --env staging   # deploy the "staging" named environment
wrangler deploy --dry-run --outdir=dist   # build only, inspect bundle, no upload
wrangler dev                    # local dev (workerd/Miniflare) at localhost:8787
wrangler dev --remote           # run on Cloudflare's edge with real bindings
wrangler tail                   # stream live logs from the deployed Worker
wrangler types                  # generate worker-configuration.d.ts from bindings
wrangler delete                 # remove the deployed Worker
```

## Environments

Named environments share one config file; each can override `vars`, bindings, routes, name.

```jsonc
{
  "name": "my-worker",
  "vars": { "ENVIRONMENT": "production" },
  "env": {
    "staging": {
      "vars": { "ENVIRONMENT": "staging" },
      "kv_namespaces": [{ "binding": "CACHE", "id": "<staging-kv-id>" }]
    }
  }
}
```

- Deploy: `wrangler deploy` (top-level / production) vs `wrangler deploy --env staging`.
- The deployed Worker is named `my-worker` for top-level and `my-worker-staging` for the named env (unless you override `name` inside the env).
- Bindings are NOT inherited into named envs by default — redeclare what each env needs.

## Secrets

| Scope | How |
|-------|-----|
| Local dev | **`.dev.vars`** (dotenv, gitignored). `wrangler dev` injects as `env.*`. Per-env: `.dev.vars.staging`. |
| Deployed | `wrangler secret put NAME` (prompts, encrypts) · `wrangler secret list` · `wrangler secret delete NAME` |
| Named env | `wrangler secret put NAME --env staging` |
| Bulk (CI) | `wrangler secret bulk secrets.json` |
| Account-shared | **Secrets Store** bindings — define a secret once at the account level, bind it into multiple Workers |

```jsonc
// Secrets Store binding
{ "secrets_store_secrets": [{ "binding": "API_KEY", "store_id": "<id>", "secret_name": "api-key" }] }
```

Rules: never put secrets in `vars` (plaintext in deployed config). Gitignore `.dev.vars*`. Rotate via `secret put` (overwrites).

## Workers Builds (native CI)

Cloudflare's git-connected build+deploy: connect a GitHub/GitLab repo in the dashboard, Cloudflare runs your build command and `wrangler deploy` on push. Zero extra CI for most projects; supports per-branch preview deployments, build env vars, and monorepo build paths. Default choice unless you need custom CI steps.

## GitHub Actions

Use `cloudflare/wrangler-action`. Authenticate with a **scoped API token**, not your global key.

```yaml
name: deploy
on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<pinned-sha>
      - uses: actions/setup-node@<pinned-sha>
        with: { node-version: 20 }
      - run: npm ci
      - uses: cloudflare/wrangler-action@<pinned-sha>
        with:
          apiToken: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          accountId: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
          command: deploy
          # secrets: |          # optional: push secrets at deploy time
          #   API_KEY
        # env:
        #   API_KEY: ${{ secrets.API_KEY }}
```

**API token scope (least privilege):** create a token with `Account > Workers Scripts > Edit` (plus `Workers KV/R2/D1` edit if the deploy provisions them). Store `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID` as repo secrets. Pin action SHAs (supply-chain hygiene), not floating tags.

Cloudflare does not offer OIDC trusted-publishing for Workers deploys today — the auth path is a scoped API token. Keep it least-privilege and rotate it; treat it like a publish credential.

## Gradual deployments + rollback

```bash
wrangler versions upload          # upload a new version, NOT live (0% traffic)
wrangler versions deploy          # interactively split traffic across versions (e.g. 10% new / 90% old)
wrangler versions list            # see versions + their traffic split
wrangler rollback [VERSION_ID]    # revert to a previous version instantly
```

Pattern: `versions upload` → `versions deploy` at 10% → watch metrics/logs → ramp to 100%, or `rollback` if it regresses. This is the safe path for risky changes vs a straight `deploy` (100% instantly).

## Observability

| Tool | Use |
|------|-----|
| **Workers Logs** | `"observability": { "enabled": true }` in config — captures `console.log`/errors, queryable in dashboard. **Off by default.** Sampling configurable (`head_sampling_rate`). |
| `wrangler tail` | Live log stream during an incident / local debugging of prod. |
| **Tail Workers** | A Worker bound to receive execution traces of another Worker — centralised logging, alerting, forwarding to a SIEM. |
| **Analytics Engine** | `env.AE.writeDataPoint(...)` for custom high-cardinality metrics; query via GraphQL/SQL Analytics API. |
| Dashboard metrics | Per-Worker requests, errors, CPU time, subrequests — built in, no setup. |

```jsonc
{ "observability": { "enabled": true, "head_sampling_rate": 1 } }
```

## Deploy safety checklist

```
□ `wrangler deploy` (not publish) — CI updated
□ compatibility_date present and intentional (bumping changes runtime behaviour)
□ secrets via `secret put` / Secrets Store — none in `vars`
□ bindings declared for the target env (named envs don't inherit)
□ risky change → versions upload + gradual deploy, not 100% deploy
□ observability enabled so you can see errors after rollout
□ API token scoped least-privilege; action SHAs pinned in the workflow
□ rollback path known: `wrangler rollback`
```
