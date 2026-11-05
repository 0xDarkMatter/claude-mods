---
name: terraform-ops
description: "Terraform and OpenTofu infrastructure-as-code operations - project layout, state management, module design, plan/apply safety, CI/CD pipelines, and secrets. Use for: terraform, opentofu, infrastructure as code, IaC, tfstate, terraform state, terraform module, remote backend, terraform plan, terraform apply, for_each, moved block, terraform import, drift detection, tflint, checkov, HCL."
license: MIT
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
  related-skills: ci-cd-ops, docker-ops, kubernetes-ops
---

# Terraform Operations

Terraform / OpenTofu infrastructure-as-code: layout, state, modules, safety, CI/CD, secrets.

**Version context (verified 2026-06):** Terraform **1.15.x** (BUSL-1.1 licence since 1.6) · OpenTofu **1.12.x** (MPL-2.0 fork of Terraform 1.5.x). Commands below are interchangeable (`terraform` ↔ `tofu`) unless flagged. See [Terraform vs OpenTofu](#terraform-vs-opentofu) for the decision note.

## Reference Files

| File | Covers |
|------|--------|
| [references/state-management.md](references/state-management.md) | Remote backends, locking, moved/import/removed blocks, state surgery, drift detection |
| [references/module-patterns.md](references/module-patterns.md) | Module composition, variable validation, optional/nullable, output contracts, versioning |
| [references/cicd-pipelines.md](references/cicd-pipelines.md) | GitHub Actions plan/apply, OIDC auth, policy gates (tflint/trivy/checkov/OPA), Atlantis/HCP |
| [references/security-and-secrets.md](references/security-and-secrets.md) | Secrets in state, ephemeral resources, write-only arguments, SOPS/Vault, sensitive limits |
| [assets/github-actions-terraform.yml](assets/github-actions-terraform.yml) | Ready-to-adapt PR-plan + OIDC-apply workflow |
| [scripts/check-action-refs.sh](scripts/check-action-refs.sh) | Staleness verifier for any workflow's `uses:` action refs (offline structural / live API resolve) |

> The action versions pinned in `github-actions-terraform.yml` are **point-in-time** (verified 2026-06). Run `scripts/check-action-refs.sh --live` before adopting — a tag that was valid at write time may have been retracted or never existed (e.g. `trivy-action@0.33.1` vs the real `v0.33.1`).

## Project Layout Decision Tree

```
How many environments / accounts?
│
├─ One environment, one team
│  └─ Single root module + tfvars. Don't over-engineer.
│
├─ Multiple environments (dev/staging/prod)
│  ├─ Need different backend/account/region per env? (usually YES for prod isolation)
│  │  └─ DIRECTORY PER ENVIRONMENT (recommended default)
│  │     environments/{dev,staging,prod}/ each a thin root calling shared modules
│  │
│  └─ Environments truly identical except a few variables, same backend account?
│     └─ Workspaces are *acceptable* — but see the workspace caveats below
│
└─ Many teams / many state files / platform engineering
   └─ Directory-per-env + per-component state split (network / data / app)
      Consider Terragrunt, Terraform Stacks (HCP), or OpenTofu + CI orchestration
```

### Canonical multi-env layout

```
infra/
├── modules/                  # Reusable child modules (no provider/backend blocks)
│   ├── network/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── versions.tf       # required_providers ONLY (no provider config)
│   └── app-service/
├── environments/             # Root modules — one state file each
│   ├── dev/
│   │   ├── main.tf           # module "network" { source = "../../modules/network" ... }
│   │   ├── backend.tf        # remote backend, env-specific key
│   │   ├── providers.tf      # provider config lives in ROOT only
│   │   ├── terraform.tfvars  # committed, non-secret env values
│   │   └── versions.tf       # required_version + required_providers pins
│   └── prod/
└── .tflint.hcl
```

### Why directories usually beat workspaces

| Concern | Directories | Workspaces |
|---------|-------------|------------|
| Separate backend/account per env | Yes — each root has its own `backend.tf` | No — one backend, envs differ only by state key |
| Blast radius of wrong-env apply | Low — you're physically in `prod/` | High — invisible `terraform workspace select` state |
| Env-specific config divergence | Natural (different main.tf if needed) | `terraform.workspace` conditionals creep everywhere |
| Prod IAM isolation | Per-dir CI role | Same credentials see all envs |
| Visibility in code review | Diff shows which env changed | Workspace is runtime state, not in the diff |

Workspaces fit short-lived ephemeral copies (PR preview envs) — not the dev/prod boundary. HashiCorp's own docs say workspaces are "not suitable for strong separation."

### tfvars conventions

```bash
terraform.tfvars            # auto-loaded — per-root committed defaults (non-secret)
*.auto.tfvars               # auto-loaded — generated/local overrides
prod.tfvars                 # explicit only: terraform plan -var-file=prod.tfvars
TF_VAR_db_password=...      # env var injection — secrets in CI, never in files
```

Gotcha: `-var-file` + directories-per-env is belt-and-braces; with workspaces it's load-bearing and one forgotten flag applies dev values to prod.

## State Quick Reference

Full detail: [references/state-management.md](references/state-management.md).

| Task | Command / block | Notes |
|------|-----------------|-------|
| Remote backend (AWS) | `backend "s3" { bucket, key, region, use_lockfile = true }` | S3-native locking (TF ≥1.10) — DynamoDB table no longer required |
| Rename resource in code | `moved { from = aws_x.a, to = aws_x.b }` | Declarative, reviewable, no CLI surgery |
| Adopt existing infra | `import { to = aws_x.a, id = "i-123" }` + `plan -generate-config-out=gen.tf` | Config-driven import (TF ≥1.5) beats `terraform import` CLI |
| Forget without destroy | `removed { from = aws_x.a, lifecycle { destroy = false } }` | TF ≥1.7; OpenTofu 1.12 also has `lifecycle { destroy = false }` on resources |
| Drift detection | `terraform plan -detailed-exitcode` | Exit 0 = clean, 1 = error, **2 = drift** — cron it |
| Inspect state | `terraform state list` / `state show ADDR` | Read-only, always safe |
| Move state (last resort) | `terraform state mv SRC DST` | Prefer `moved` blocks — see "when NOT to" below |
| Pull/push (emergency) | `terraform state pull > backup.tfstate` | ALWAYS pull a backup before any surgery |

**State surgery — when NOT to:** if a `moved`/`removed`/`import` block can express it, use the block. CLI `state mv`/`rm` is immediate, unreviewed, unversioned, and a typo orphans real infrastructure. Legit uses: splitting state between roots, unwedging a failed migration. Always `state pull` a backup first.

## Module Quick Reference

Full detail: [references/module-patterns.md](references/module-patterns.md).

```hcl
module "network" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"          # pin minor-float for registry modules; exact pin in prod roots
  # ...
}
```

| Rule | Why |
|------|-----|
| Composition over inheritance | Roots compose flat modules; never module-wraps-module-wraps-module |
| No provider blocks in child modules | Providers configured in root only; child declares `required_providers` |
| `validation` blocks on variables | Fail at plan with a real message, not mid-apply |
| `optional(type, default)` in object attrs | Callers omit fields; `nullable = false` rejects explicit null |
| Outputs are the contract | Output IDs/ARNs consumers need; document with `description` |
| **Anti-pattern: thin wrappers** | A module that just renames variables of another module adds a version-lag layer and zero value — call the upstream module directly |

## Safety Checklist (before every apply)

```
□ plan output READ, not skimmed — every destroy/replace explained
□ "Plan: X to add, Y to change, Z to destroy" — does Z surprise you?
□ -/+ (replace) lines: check the "forces replacement" attribute
□ Applying the SAME saved plan that was reviewed: plan -out=tfplan → apply tfplan
□ prevent_destroy on stateful resources (db, state bucket, KMS keys)
□ Cloud-side deletion protection too (RDS deletion_protection, S3 versioning+MFA-delete)
□ No -target unless this is a declared emergency (see below)
□ for_each (stable keys), not count, for any collection that can reorder
```

### Footguns

| Footgun | Detail | Fix |
|---------|--------|-----|
| `count` index shift | Removing item 0 of a `count` list re-addresses every later item → destroy/recreate cascade | `for_each` with stable string keys |
| `-target` habit | Skips dependency graph; state diverges from config; hides drift | Emergency-only (broken dependency cycle, partial outage). Follow with a full clean plan |
| `prevent_destroy` false comfort | Doesn't survive the block being deleted, and doesn't stop `state rm` + console delete | Pair with cloud-native deletion protection |
| Dynamic blocks everywhere | `dynamic` for 2 static blocks is obfuscation | Use `dynamic` only over genuinely variable collections |
| Unpinned providers | `aws = ">= 5.0"` in prod pulls a breaking major the day it ships | `~> 6.12` + commit `.terraform.lock.hcl` |
| Apply ≠ reviewed plan | Plan on PR, apply on merge re-plans — drift in between applies unreviewed changes | Save the plan artifact, or accept + re-review the merge plan |

```hcl
resource "aws_db_instance" "main" {
  deletion_protection = true            # cloud-side
  lifecycle {
    prevent_destroy = true              # terraform-side
    ignore_changes  = [password]        # if rotated outside TF
  }
}
```

## CI/CD Quick Reference

Full detail: [references/cicd-pipelines.md](references/cicd-pipelines.md) · template: [assets/github-actions-terraform.yml](assets/github-actions-terraform.yml).

```
PR opened   → fmt -check → validate → tflint → trivy/checkov → plan → plan posted as PR comment
PR merged   → plan (fresh) → apply, authenticated via OIDC — no long-lived cloud keys
Nightly     → plan -detailed-exitcode → exit 2 ⇒ drift alert
```

- **OIDC everywhere** — `aws-actions/configure-aws-credentials` with `role-to-assume`, never `AWS_ACCESS_KEY_ID` secrets. Same supply-chain doctrine as this repo's rules: short-lived tokens, no standing credentials.
- **Pin action SHAs** in workflows (`uses: actions/checkout@<sha>`), not floating tags.
- Policy gates: `tflint` (provider-aware lint), `trivy config` / `checkov` (misconfig scan), OPA/`conftest` for org policy ("no public buckets").

| Orchestrator | Fit |
|---|---|
| Plain GitHub Actions | Default — full control, free, template in assets/ |
| Atlantis | Self-hosted PR automation, `atlantis plan/apply` comments, locking per dir |
| HCP Terraform / Terraform Cloud | Managed runs, Sentinel policy, state hosting; free ≤500 resources |
| Spacelift / env0 / Digger / Scalr | Commercial Atlantis-likes; Digger runs inside your Actions |

### Verification — `uses:` ref staleness

GitHub Action versions rot: a tag gets retracted, or a workflow pins one that never existed. [scripts/check-action-refs.sh](scripts/check-action-refs.sh) lints every `uses: owner/repo@ref` line. It's **general** — pass any workflow file(s) as positionals (default: this skill's own `assets/github-actions-terraform.yml`).

```bash
# Structural only, no network — well-formedness of every uses: ref (CI-safe gate).
# Floating @main/@master → WARN (exit 0; use --strict to fail). Malformed → exit 4.
scripts/check-action-refs.sh --offline .github/workflows/ci.yml

# Live — resolve each ref against the GitHub API. A 404 (ref doesn't exist) → exit 10
# DRIFT; API unreachable/rate-limited → exit 7 (advisory, never fails the build, §7).
# Set GITHUB_TOKEN to dodge the unauthenticated rate limit.
GITHUB_TOKEN=$GH_PAT scripts/check-action-refs.sh --live .github/workflows/*.yml

scripts/check-action-refs.sh --json --offline | jq '.data[] | select(.status!="ok")'
```

`--live` is the check that catches the classic `aquasecurity/trivy-action@0.33.1` mistake — that tag 404s; the real one is `v0.33.1`. Run live on a schedule (never as a blocking PR gate), offline in PR CI.

## Testing Quick Reference

```hcl
# tests/network.tftest.hcl  — native test framework (TF ≥1.6 / OpenTofu ≥1.6)
variables { cidr = "10.0.0.0/16" }

run "valid_cidr_plan" {
  command = plan                          # plan = fast unit-ish; apply = real integration
  assert {
    condition     = aws_vpc.main.cidr_block == "10.0.0.0/16"
    error_message = "VPC CIDR did not match input"
  }
}

run "rejects_tiny_cidr" {
  command = plan
  variables { cidr = "10.0.0.0/30" }
  expect_failures = [var.cidr]            # asserts the validation block fires
}
```

`terraform test` runs every `*.tftest.hcl` under `tests/`; `command = apply` runs create real (then auto-destroyed) infra — use a sandbox account. Mock providers (`mock_provider` blocks, TF ≥1.7) fake apply without credentials. For multi-tool/Go-level orchestration (retry, real HTTP probes), Terratest is the heavyweight alternative — native `terraform test` covers most module CI needs first.

## Secrets Quick Reference

Full detail: [references/security-and-secrets.md](references/security-and-secrets.md).

| Mechanism | Version | What it does |
|---|---|---|
| `sensitive = true` | all | Redacts from CLI output **only** — value still plaintext in state |
| Ephemeral resources (`ephemeral "..."`) | TF ≥1.10 / OpenTofu ≥1.11 | Fetch secret at run time; never persisted to state or plan |
| Write-only arguments (`password_wo`) | TF ≥1.11 / OpenTofu ≥1.11 | Send secret to provider; never stored in state; rotate via `_wo_version` |
| SOPS-encrypted tfvars | tool | Secrets encrypted at rest in git; decrypted at plan time |
| Vault / cloud secret manager | tool | Reference by ID; resource reads secret at boot, TF never sees it |
| OpenTofu state encryption | OpenTofu ≥1.7 | Client-side AES-GCM encryption of state/plan — **no Terraform equivalent** |

**Rule zero: treat state as secret regardless.** Encrypt the backend (SSE-KMS), restrict IAM on the bucket, never commit `*.tfstate` (gitignore it).

## Terraform vs OpenTofu

| | Terraform | OpenTofu |
|---|---|---|
| Licence | **BUSL-1.1** since 1.6 (no production use *competing with HashiCorp*; fine for normal internal use) | **MPL-2.0** — genuinely open source, Linux Foundation |
| Current | 1.15.x | 1.12.x |
| Exclusive features | Stacks (HCP-tied), Terraform Cloud agents, `terraform query` | State/plan **encryption**, provider `for_each` iteration, `-exclude` flag, early variable eval in backend/module blocks, OCI registry distribution, `.tofu` file extension |
| Registry | registry.terraform.io | registry.opentofu.org (mirrors most providers) |
| Compatibility | — | Forked at 1.5.x; HCL/state compatible for mainstream use, diverging feature-by-feature since |

**Decision:** vendors and anyone redistributing IaC tooling commercially → OpenTofu (licence risk). Teams on HCP Terraform/Sentinel → Terraform. Everyone else: either works; OpenTofu's state encryption is the single biggest technical differentiator. Migration `terraform → tofu` is `tofu init` + state-compatible up to ~1.8-era features; the gap widens each release — migrate early or commit.

## Command Quick Reference

```bash
terraform init -upgrade               # init / upgrade providers within constraints
terraform fmt -recursive -check       # CI: fail on unformatted
terraform validate                    # syntax + internal consistency (no creds needed after init)
terraform plan -out=tfplan            # save plan for exact-apply
terraform show -json tfplan | jq      # machine-readable plan (policy tools eat this)
terraform apply tfplan                # apply EXACTLY the reviewed plan
terraform plan -detailed-exitcode     # 0 clean / 2 drift — for cron drift checks
terraform plan -refresh-only          # show drift without proposing config changes
terraform apply -replace=aws_x.a      # force recreate one resource (replaces old taint)
terraform state pull > backup.json    # ALWAYS before surgery
terraform output -json                # consume outputs in scripts
terraform graph | dot -Tsvg > g.svg   # dependency graph
tofu init                             # OpenTofu: same verbs throughout
```
