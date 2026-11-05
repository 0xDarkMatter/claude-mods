# Security and Secrets

The uncomfortable truth first: **Terraform state stores resource attributes in plaintext JSON** — including any password, key, token, or connection string a provider ever returned. `sensitive = true` changes what's *printed*, not what's *stored*. Every secrets strategy below is a variation on "make sure the secret never enters state, and harden state anyway."

## Threat Model

| Surface | Exposure | Mitigation |
|---|---|---|
| State file | Plaintext attributes of every resource | Encrypted backend + IAM; OpenTofu state encryption; keep secrets out entirely (below) |
| Plan files (`tfplan`, JSON) | Contain proposed values, incl. some sensitive ones | Treat plan artifacts as secrets; short retention on CI artifacts |
| CLI / CI logs | Values interpolated into output | `sensitive = true`, `-no-color` log review, masked CI vars |
| PR plan comments | Anyone with repo read | Summarize rather than full-dump for sensitive roots |
| `.tfvars` in git | Whatever you put there | Never commit secret tfvars; SOPS-encrypt or env-var inject |
| Provider credentials | Long-lived keys in CI secrets | OIDC short-lived tokens (see cicd-pipelines.md) |

## What `sensitive = true` Actually Does (and doesn't)

```hcl
variable "db_password" {
  type      = string
  sensitive = true        # plan/apply output prints (sensitive value)
}

output "endpoint" {
  value     = "${aws_db_instance.main.address}:${var.db_password}"  # ERROR unless...
  sensitive = true        # ...the output is marked too (sensitivity propagates)
}
```

Does: redact from `plan`/`apply`/`output` human output; propagate taint through expressions; force derived outputs to be marked.
Does **not**: encrypt anything; remove the value from state (`terraform state pull | jq` shows it plaintext); redact from `terraform output -json` (explicitly prints sensitive values); stop a provider logging it at TRACE.

`ephemeral = true` on variables (TF ≥ 1.10) goes further: the value may only flow into ephemeral contexts (write-only args, provider config, locals marked ephemeral) and is never written to state or plan.

## Ephemeral Resources (TF ≥ 1.10, OpenTofu ≥ 1.11)

Ephemeral resources open/fetch a value during the run and are **never persisted to state or plan**. The first-class pattern for "read a secret from a manager at apply time."

```hcl
# Fetch the secret ephemerally — exists only for the duration of the run
ephemeral "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
}

# Use it via a write-only argument so it never lands in state either
resource "aws_db_instance" "main" {
  # ...
  password_wo         = ephemeral.aws_secretsmanager_secret_version.db.secret_string
  password_wo_version = 1
}
```

Available ephemeral resource types include `aws_secretsmanager_secret_version`, `aws_ssm_parameter`, `azurerm_key_vault_secret`, `google_secret_manager_secret_version`, Vault's `vault_kv_secret_v2`, and `random_password` (ephemeral variant). Ephemeral *values* can feed: write-only arguments, provider configuration, `terraform_data` triggers — anything that itself persists will error if you try.

Contrast with the classic `data "aws_secretsmanager_secret_version"` — a data source's result **is stored in state**, which quietly copied your secret into the state file. Migrate those reads to `ephemeral` blocks.

## Write-Only Arguments (TF ≥ 1.11, OpenTofu ≥ 1.11)

Provider-defined `*_wo` arguments accept a value, hand it to the API, and store **nothing** in state. Because nothing is stored, Terraform can't diff them — that's what the paired `*_wo_version` integer is for:

```hcl
resource "aws_db_instance" "main" {
  password_wo         = var.db_password          # never in state
  password_wo_version = 2                        # bump to push a new password
}
```

- Rotate by incrementing `_wo_version` (or wiring it to a rotation timestamp/secret version).
- Write-only args accept ephemeral values — the combination above (ephemeral read → write-only write) is the zero-secrets-in-state gold standard.
- Caveat: not every provider/resource has `_wo` variants yet; check the provider docs. Where absent, fall back to the secret-manager-reference pattern below.

## Pattern Ladder (best to worst)

```
1. Secret never touches Terraform at all
   App reads from Secrets Manager/Vault at BOOT using its IAM role;
   Terraform only creates the (empty or rotated-out-of-band) secret container + IAM.

2. Ephemeral read -> write-only write          (TF >= 1.11)
   Secret transits the run in memory only. Nothing in state or plan.

3. Secret manager reference via data source    (any version)
   data "aws_secretsmanager_secret_version" -- secret IS in state,
   but at least it's centrally rotated + audited. Encrypt state, restrict IAM.

4. TF_VAR_ env injection from CI secret store  (any version)
   Keeps secrets out of git; still lands in state if assigned to a resource attribute.

5. SOPS-encrypted tfvars in git
   Good at-rest story for git; same state caveat as 4.

6. Plaintext in tfvars/locals committed to git
   Never. Rotating means rewriting git history.
```

### Vault / cloud secret manager integration

```hcl
# Terraform creates the container + access policy; VALUE is set out-of-band or by rotation lambda
resource "aws_secretsmanager_secret" "db" {
  name       = "prod/db/password"
  kms_key_id = aws_kms_key.secrets.arn
}

resource "aws_iam_role_policy" "app_reads_secret" {
  role   = aws_iam_role.app.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "secretsmanager:GetSecretValue",
                   Resource = aws_secretsmanager_secret.db.arn }]
  })
}
# App fetches the secret at startup. Terraform never knows the value.
```

Vault: prefer short-TTL dynamic secrets (`vault_database_secret_backend_role`) so even a leaked credential expires in minutes. The Vault provider's classic data sources persist to state — use the ephemeral variants on TF ≥ 1.10.

### SOPS pattern

```bash
# Encrypt env tfvars with a KMS key; ciphertext is committable
sops --encrypt --kms arn:aws:kms:...:key/... prod.tfvars.json > prod.sops.tfvars.json
```

```hcl
# Via carlpett/sops provider
data "sops_file" "secrets" { source_file = "prod.sops.tfvars.json" }
locals { db_password = data.sops_file.secrets.data["db_password"] }
```

Honest accounting: decrypted values still flow into plan/state unless they terminate in write-only arguments. SOPS solves *git at-rest*, not *state at-rest*.

## Hardening State Itself

Do all of this regardless of which pattern above you use:

- Backend encryption: S3 SSE-KMS with a dedicated CMK; bucket policy denying un-encrypted puts; `azurerm`/`gcs` with CMK.
- IAM: state bucket readable only by the CI roles + break-glass group. State read access ≈ secret read access — treat the grant accordingly.
- Versioning on (recovery) + access logging on the bucket (audit).
- `.gitignore`: `*.tfstate`, `*.tfstate.*`, `*.tfplan`, `.terraform/`, and crash logs (`crash.log` can embed values).
- **OpenTofu state encryption** (≥ 1.7) — client-side AES-GCM over state *and* plan files, key from PBKDF2 passphrase, AWS/GCP KMS, Azure Key Vault, or external program. The strongest state story available; Terraform has no equivalent (config sample in state-management.md). Plan key rotation: `encryption` supports a `fallback` method so old state remains readable during rotation.

## Provider Credential Hygiene

| Don't | Do |
|---|---|
| `provider "aws" { access_key = "..." }` hardcoded | Ambient auth: OIDC in CI, SSO/instance profiles locally |
| Long-lived `AWS_ACCESS_KEY_ID` in CI secrets | OIDC `role-to-assume` (see cicd-pipelines.md) |
| One god-role for plan and apply | Read-only plan role; write apply role gated to main/environment |
| Shared human credentials for break-glass | Named identities + audited assume-role |

## Scanning and Gates

- `trivy config .` / `checkov -d .` catch *misconfigurations* (public buckets, `0.0.0.0/0` ingress, unencrypted volumes) — wire into PR CI (see cicd-pipelines.md).
- `gitleaks` / pre-push scans (`push-preflight`) catch secrets *in the repo* — tfvars are a classic leak vector.
- `terraform providers` + lockfile review on provider bumps: providers execute arbitrary code on your CI runner with cloud credentials. A provider is a dependency — the repo's supply-chain rules (cooldown, behavioural scan before adopting unfamiliar providers from the registry) apply in full.
