# Kubernetes Manifests

Production manifests for Kubernetes 1.35-1.37. The workload itself (Deployment, Service,
route) is in SKILL.md; this file covers what surrounds it.

## Contents

- [Namespace with Pod Security enforced](#namespace-with-pod-security-enforced)
- [Config and secrets](#config-and-secrets)
- [Autoscaling](#autoscaling)
- [Disruption budgets and spreading](#disruption-budgets-and-spreading)
- [NetworkPolicy](#networkpolicy)
- [ServiceAccount and RBAC](#serviceaccount-and-rbac)
- [Sidecars, Jobs and CronJobs](#sidecars-jobs-and-cronjobs)
- [Service traffic and EndpointSlices](#service-traffic-and-endpointslices)

## Namespace with Pod Security enforced

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: shop
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/warn: restricted
    gateway-access: "true"          # lets this namespace attach routes to the shared Gateway
```

Pod Security Admission replaced PodSecurityPolicy (removed in 1.25). Under `restricted`, a
pod must set `runAsNonRoot: true` (and must not run as UID 0), `allowPrivilegeEscalation:
false`, drop `ALL` capabilities (only `NET_BIND_SERVICE` may be added back) and use a
`RuntimeDefault` or `Localhost` seccomp profile. It may only use the volume types the
standard lists (configMap, csi, downwardAPI, emptyDir, ephemeral, persistentVolumeClaim,
projected, secret). Roll out with `warn` (or `audit`) first, then `enforce`.

## Config and secrets

```yaml
apiVersion: v1
kind: ConfigMap
metadata: {name: web-config, namespace: shop}
data:
  LOG_LEVEL: info
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: {name: web-secrets, namespace: shop}
spec:
  refreshInterval: 1h
  secretStoreRef: {name: aws-secrets-manager, kind: ClusterSecretStore}
  target: {name: web-secrets}
  data:
    - secretKey: DATABASE_URL
      remoteRef: {key: shop/database-url}
```

```yaml
          envFrom:
            - configMapRef: {name: web-config}
          env:
            - name: DATABASE_URL
              valueFrom: {secretKeyRef: {name: web-secrets, key: DATABASE_URL}}
```

- A `Secret` manifest with `data:` in git is a leaked secret: base64 is an encoding.
  External Secrets Operator (above), Sealed Secrets, or the Secrets Store CSI driver keep
  the value out of git.
- A changed ConfigMap does not restart pods that read it as env vars. Roll them
  (`kubectl rollout restart deployment/web`), or hash the config into a pod annotation
  (Helm does this with a `checksum/config` annotation).
- Since 1.37, static pods cannot reference Secrets or ConfigMaps at all.

## Autoscaling

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: {name: web, namespace: shop}
spec:
  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: web}
  minReplicas: 3
  maxReplicas: 20
  metrics:
    - type: Resource
      resource: {name: cpu, target: {type: Utilization, averageUtilization: 70}}
  behavior:
    scaleDown: {stabilizationWindowSeconds: 300, policies: [{type: Percent, value: 20, periodSeconds: 60}]}
```

- HPA utilisation is measured against **requests**: a pod without CPU requests never scales.
- Since 1.35, in-place resize changes a running pod's requests and limits without a
  restart (`kubectl patch pod ... --subresource resize`). It is useful for vertical
  tuning, but the controller's template still decides new pods.
- Configurable HPA tolerance (the band before it reacts) is GA in 1.37. HPA scale-to-zero
  is beta in 1.37: check that your cluster (or managed provider) enables it before you set
  `minReplicas: 0`.

## Disruption budgets and spreading

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: {name: web, namespace: shop}
spec:
  maxUnavailable: 1
  unhealthyPodEvictionPolicy: AlwaysAllow
  selector: {matchLabels: {app.kubernetes.io/name: web}}
```

```yaml
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector: {matchLabels: {app.kubernetes.io/name: web}}
```

Without a PDB, a node drain can take every replica at once. `AlwaysAllow` stops pods that
are already unhealthy from blocking a drain.

## NetworkPolicy

Default-deny, then open what's needed. A policy does nothing unless the CNI enforces
NetworkPolicy (Calico, Cilium and most managed CNIs do).

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: default-deny, namespace: shop}
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: web, namespace: shop}
spec:
  podSelector: {matchLabels: {app.kubernetes.io/name: web}}
  policyTypes: [Ingress, Egress]
  ingress:
    - from: [{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: gateway}}}]
      ports: [{protocol: TCP, port: 8080}]
  egress:
    - to: [{podSelector: {matchLabels: {app.kubernetes.io/name: postgres}}}]
      ports: [{protocol: TCP, port: 5432}]
    - to: [{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}}]
      ports: [{protocol: UDP, port: 53}, {protocol: TCP, port: 53}]
```

`kubernetes.io/metadata.name` is set on every namespace automatically, so you never need a
hand-added `name:` label. Default-deny egress blocks DNS too, hence the last rule.

## ServiceAccount and RBAC

```yaml
apiVersion: v1
kind: ServiceAccount
metadata: {name: web, namespace: shop}
automountServiceAccountToken: false
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: web-read-config, namespace: shop}
rules:
  - apiGroups: [""]
    resources: [configmaps]
    resourceNames: [web-config]
    verbs: [get, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: web-read-config, namespace: shop}
subjects: [{kind: ServiceAccount, name: web, namespace: shop}]
roleRef: {kind: Role, name: web-read-config, apiGroup: rbac.authorization.k8s.io}
```

Most apps never call the API: turn the token off (`automountServiceAccountToken: false`).
Grant by `resourceNames` where you can; `list` and `watch` on Secrets amount to reading all of them.

## Sidecars, Jobs and CronJobs

Native sidecars (GA in 1.33) are init containers with `restartPolicy: Always`. They start
before the app, keep running beside it, and stop after it, so a Job no longer hangs on a
log shipper that never exits:

```yaml
      initContainers:
        - name: log-shipper
          image: ghcr.io/acme/log-shipper:2.3.1
          restartPolicy: Always
      containers:
        - name: app
          image: ghcr.io/acme/app:1.4.0
```

```yaml
apiVersion: batch/v1
kind: CronJob
metadata: {name: cleanup, namespace: shop}
spec:
  schedule: "0 2 * * *"
  timeZone: Etc/UTC
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 3600
      ttlSecondsAfterFinished: 86400
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: cleanup
              image: ghcr.io/acme/app:1.4.0
              args: [cleanup]
```

Set `timeZone` (the default is the controller's zone), `concurrencyPolicy: Forbid` for
anything that must not overlap, and a TTL so finished Jobs don't pile up.

## Service traffic and EndpointSlices

- The `Endpoints` API is deprecated (1.33); tools and debugging use EndpointSlices:
  `kubectl get endpointslices -l kubernetes.io/service-name=web`.
- `spec.trafficDistribution: PreferSameZone` keeps traffic in-zone when possible (it
  replaces `PreferClose`, deprecated in 1.34); `PreferSameNode` prefers the local node.
- `spec.externalIPs` is deprecated (1.36): use a `LoadBalancer` Service or a Gateway.
