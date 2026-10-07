# Helm Chart Patterns

Charts and releases with Helm 4 (current: 4.3, 2026-09). Helm 3's last feature release was
3.22 (2026-09). Helm 3 gets security fixes until 2027-02-10, so plan the move.

## Contents

- [What Helm 4 changed](#what-helm-4-changed)
- [Chart layout](#chart-layout)
- [Chart.yaml and dependencies](#chartyaml-and-dependencies)
- [values.yaml and its schema](#valuesyaml-and-its-schema)
- [Templates worth copying](#templates-worth-copying)
- [Releases: the safe commands](#releases-the-safe-commands)
- [OCI registries](#oci-registries)
- [Testing a chart](#testing-a-chart)

## What Helm 4 changed

| Area | Helm 4 | What to do |
|---|---|---|
| Apply method | **server-side apply** for new releases; releases created by Helm 3 keep client-side apply until you pass `--server-side` | expect field-ownership conflicts where other controllers edit the same fields |
| Flags | `--atomic` is `--rollback-on-failure`; `--force` is `--force-replace` | the old flags still work, with a warning: update scripts and CI |
| Waiting | `--wait` uses kstatus (it understands the readiness of more resource kinds) | |
| Post-renderers | `--post-renderer` takes a **plugin name**, not a path to an executable | wrap a kustomize step as a plugin |
| Registry login | `helm registry login ghcr.io`: a domain only, no path | |
| OCI installs | pin by digest: `helm install web oci://ghcr.io/acme/charts/web@sha256:<digest>` | |
| Values | multi-document values files work | |
| Charts | `apiVersion: v2` charts are unchanged; Charts v3 is experimental (`HELM_EXPERIMENTAL_CHART_V3=1`) | keep writing v2 charts |

## Chart layout

```
web/
├── Chart.yaml
├── values.yaml
├── values.schema.json        # rejects bad values at install time
├── templates/
│   ├── _helpers.tpl
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── httproute.yaml        # Gateway API (ingress-nginx is retired)
│   ├── hpa.yaml
│   ├── pdb.yaml
│   ├── serviceaccount.yaml
│   └── NOTES.txt
└── charts/                   # vendored dependencies (from `helm dependency build`)
```

## Chart.yaml and dependencies

```yaml
apiVersion: v2
name: web
description: The shop's web tier
type: application
version: 1.4.0          # the chart's version: bump on every chart change
appVersion: "1.4.0"     # the app's version: the default image tag
dependencies:
  - name: redis
    version: "~1.6.0"
    repository: oci://ghcr.io/acme/charts
    condition: redis.enabled
```

- Commit `Chart.lock` and run `helm dependency build` in CI. `helm dependency update`
  re-resolves the ranges, which is the chart equivalent of rewriting a lockfile.
- Know what a third-party chart pulls. Bitnami's free catalog changed in 2025 (most images
  moved to a legacy repository that no longer gets updates). Check the images a Bitnami
  chart references before you depend on it, or prefer an operator (CloudNativePG for
  PostgreSQL) or the project's own chart.

## values.yaml and its schema

```yaml
replicaCount: 3
image:
  repository: ghcr.io/acme/web
  tag: ""                 # defaults to appVersion
  digest: ""              # set in production: repository@digest wins over the tag
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 10001
  seccompProfile: {type: RuntimeDefault}
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities: {drop: [ALL]}
resources:
  requests: {cpu: 100m, memory: 128Mi}
  limits: {memory: 256Mi}
route:
  enabled: true
  parentRef: {name: public, namespace: gateway, sectionName: https}
  hostnames: [shop.example.com]
autoscaling: {enabled: true, minReplicas: 3, maxReplicas: 20, targetCPUUtilizationPercentage: 70}
pdb: {enabled: true, maxUnavailable: 1}
```

A `values.schema.json` (JSON Schema) is validated on install, upgrade, lint and template:
a typo like `replicacount` fails immediately instead of being silently ignored. Mark
security-relevant keys `required` and give enums for anything with a closed set.

## Templates worth copying

The image reference, with the digest preferred over the tag:

```yaml
{{- define "web.image" -}}
{{- if .Values.image.digest -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- else -}}
{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}
{{- end -}}
{{- end -}}
```

Roll pods when their config changes:

```yaml
  template:
    metadata:
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
```

A Gateway API route instead of an Ingress:

```yaml
{{- if .Values.route.enabled }}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ include "web.fullname" . }}
  labels: {{- include "web.labels" . | nindent 4 }}
spec:
  parentRefs:
    - {{- toYaml .Values.route.parentRef | nindent 6 }}
  hostnames: {{- toYaml .Values.route.hostnames | nindent 4 }}
  rules:
    - backendRefs:
        - name: {{ include "web.fullname" . }}
          port: {{ .Values.service.port }}
{{- end }}
```

Standard labels: `app.kubernetes.io/name`, `instance`, `version`, `managed-by` and
`helm.sh/chart` go in `_helpers.tpl`, and the selector uses only `name` and `instance`. A
selector can't change after install.

## Releases: the safe commands

```bash
kubectl config current-context                                  # first, every time
helm lint ./web --strict
helm template web ./web -f values-prod.yaml | kubeconform -strict -summary
helm diff upgrade web ./web -f values-prod.yaml                 # helm-diff plugin: what will change
helm upgrade --install web ./web -n shop --create-namespace \
  -f values-prod.yaml --rollback-on-failure --wait --timeout 5m
helm history web -n shop
```

- `upgrade --install` is idempotent: it installs or upgrades. `--rollback-on-failure`
  (Helm 3's `--atomic`) restores the previous release when the upgrade fails or times out.
- `helm rollback web <revision>` and `helm uninstall web` are Tier 2: name what changes or
  goes, and confirm. Rollback does not undo database migrations. Uninstall keeps PVCs made
  from StatefulSet templates.
- Don't pipe `helm template` into `kubectl apply` for releases you want to roll back:
  Helm's release record (and so `history` and `rollback`) only exists through
  `install`/`upgrade`.
- Secrets in values files: use `--set-file` from a secret manager at deploy time, or the
  External Secrets pattern in the chart. Never a `values-prod.yaml` with passwords in git.

## OCI registries

```bash
helm registry login ghcr.io                          # domain only in Helm 4
helm package ./web && helm push web-1.4.0.tgz oci://ghcr.io/acme/charts
helm install web oci://ghcr.io/acme/charts/web --version 1.4.0
helm install web oci://ghcr.io/acme/charts/web@sha256:<digest>      # immutable
```

Sign charts the same way as images (cosign on the OCI artefact) and verify them in the
deploy pipeline. Signing an image: docker-ops' supply-chain-and-scanning.md.

## Testing a chart

- `helm lint --strict`, then render every values file you ship and validate the output with
  `kubeconform` (add the Gateway API CRD schemas, or it skips HTTPRoute).
- `helm unittest` (plugin) asserts on rendered templates: put a test on each conditional
  and on the security context.
- `ct lint-and-install` (chart-testing) installs the chart into a throwaway kind cluster in
  CI. It is the only test that proves the release actually becomes ready.
