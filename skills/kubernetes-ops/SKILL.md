---
name: kubernetes-ops
description: "Kubernetes and Helm in practice: Deployments, Services, probes, resources, autoscaling, disruption budgets, NetworkPolicy, Pod Security Standards, Gateway API (ingress-nginx is retired), Helm 4 charts and releases, and kubectl without accidents. ECS and EKS specifics go to AWS's aws-containers skill, Flux to fluxcd/agent-skills. Not for Dockerfiles or Compose (docker-ops)."
when_to_use: "Use when writing or reviewing Kubernetes manifests or Helm charts, migrating off ingress-nginx, upgrading to Helm 4, hardening pods to the restricted Pod Security Standard, or debugging CrashLoopBackOff, Pending, ImagePullBackOff or OOMKilled pods. Also for ECS-vs-Kubernetes choices, and before kubectl delete, helm uninstall or a namespace teardown."
license: MIT
compatibility: "Kubernetes 1.35-1.37, Helm 4 (Helm 3 gets security fixes until 2027-02-10), Gateway API v1.6"
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
  owns: "kubernetes, kubectl, helm, gateway-api, pod-security, ecs-choice"
  related-skills: "docker-ops, terraform-ops, ci-cd-ops, monitoring-ops, security-ops"
---

# Kubernetes Operations

Manifests, charts and day-two kubectl for Kubernetes 1.35-1.37. Facts verified 2026-10-07:
Kubernetes 1.37 "Garhwal" is current (1.34 reaches end of life on 2026-10-27), Helm 4 is
current, and Gateway API v1.6 is the routing API. docker-ops'
`scripts/check-docker-facts.py --live` watches these versions weekly.

**Why:** a manifest that applies cleanly can still take production down. A pod with no
readiness probe takes traffic before it can serve; a namespace delete takes its volumes
with it; an Ingress controller that stopped getting security fixes in March 2026 is still
routing traffic in most clusters.

## Hard rules

1. **Know where you are before you write.** Run `kubectl config current-context` before any
   apply, delete or Helm command, and name the context when you report. Deletes, `apply
   --prune`, `helm uninstall` and namespace teardown are Tier 2: list what goes, ask, wait
   ([docker-ops destructive-commands.md](../docker-ops/references/destructive-commands.md)
   has the Kubernetes and Helm table).
2. **New routes use Gateway API, not ingress-nginx.** ingress-nginx was retired: no
   releases or security fixes since March 2026, and the repo is archived. Existing
   installs keep working until a CVE lands. InGate was retired too, so it is not the
   successor. Migrate with Ingress2Gateway. [gateway-api.md](references/gateway-api.md)
3. **Pods meet the restricted Pod Security Standard.** `runAsNonRoot: true` with a
   numeric `runAsUser`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`,
   `seccompProfile.type: RuntimeDefault`. `readOnlyRootFilesystem: true` is recommended,
   but Restricted does not require it. Enforce with the namespace label
   `pod-security.kubernetes.io/enforce: restricted`.
4. **Every container has requests, a memory limit, and probes that mean different things.**
   readiness = "send me traffic", liveness = "restart me", startup = "I'm still booting". A
   liveness probe that checks a database restarts healthy pods when the database blips.
5. **Images by version, and by digest in production.** Never `:latest` (and never
   `imagePullPolicy: Always` as a substitute for pinning). The image itself is docker-ops' job.
6. **A Secret is base64, not encryption.** Never commit Secret manifests with data. Use
   External Secrets Operator, Sealed Secrets or the Secrets Store CSI driver, and limit
   `get secrets` in RBAC.
7. **Helm 4 changed defaults.** New releases use server-side apply. `--atomic` is now
   `--rollback-on-failure` and `--force` is `--force-replace` (the old flags warn).
   Post-renderers are plugins. Rendering with `helm template | kubectl apply` loses release
   tracking and rollback. [helm-patterns.md](references/helm-patterns.md)
8. **Preview before changing a shared cluster:** `kubectl diff -f ...` and
   `kubectl apply --dry-run=server -f ...`. Prefer GitOps over hand-applies for anything
   long-lived.

## Routing

| The task | Where |
|---|---|
| Deployment, Service, probes, HPA, PDB, NetworkPolicy, RBAC, Jobs | [k8s-manifests.md](references/k8s-manifests.md) |
| Charts, values, Helm 4 upgrades, OCI charts | [helm-patterns.md](references/helm-patterns.md) |
| Ingress, TLS, routing, leaving ingress-nginx | [gateway-api.md](references/gateway-api.md) |
| ECS vs Kubernetes, Fargate basics | [ecs-fargate.md](references/ecs-fargate.md); details: AWS's `aws-containers` skill |
| EKS specifics (Auto Mode, Karpenter, Load Balancer Controller) | AWS's `aws-containers` skill (aws/agent-toolkit-for-aws) |
| Flux GitOps | fluxcd/agent-skills (`gitops-knowledge`, `gitops-repo-audit`, `gitops-cluster-debug`) |
| Dockerfiles, images, Compose, the local engine | docker-ops |
| Cluster infrastructure as code | terraform-ops |
| Metrics, alerts, dashboards | monitoring-ops |

Argo CD has no official agent skill (argoproj-labs ships an MCP server).

## What changed recently (1.33-1.37)

| Release | Change that matters in manifests |
|---|---|
| 1.33 | sidecar containers GA (`initContainers` with `restartPolicy: Always`); the Endpoints API is deprecated, use EndpointSlice |
| 1.34 | `trafficDistribution: PreferSameZone` replaces `PreferClose`; `PreferSameNode` added; PreStop `sleep` GA |
| 1.35 | in-place pod resize GA; kubelet refuses cgroup v1 nodes by default; kube-proxy `ipvs` mode deprecated (use nftables) |
| 1.36 | user namespaces GA (`hostUsers: false`); OCI image volumes GA; Service `externalIPs` deprecated |
| 1.37 | KYAML output (`kubectl get -o kyaml`); configurable HPA tolerance GA; static pods can no longer reference Secrets or ConfigMaps |

## A workload in one screen

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: {name: web, labels: {app.kubernetes.io/name: web}}
spec:
  replicas: 3
  selector: {matchLabels: {app.kubernetes.io/name: web}}
  template:
    metadata: {labels: {app.kubernetes.io/name: web}}
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: web
          image: ghcr.io/acme/web:1.4.0@sha256:<digest>
          ports: [{name: http, containerPort: 8080}]
          resources:
            requests: {cpu: 100m, memory: 128Mi}
            limits: {memory: 256Mi}
          readinessProbe: {httpGet: {path: /ready, port: http}, periodSeconds: 5}
          livenessProbe: {httpGet: {path: /live, port: http}, periodSeconds: 20, failureThreshold: 3}
          startupProbe: {httpGet: {path: /live, port: http}, failureThreshold: 30, periodSeconds: 2}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
          volumeMounts: [{name: tmp, mountPath: /tmp}]
      volumes: [{name: tmp, emptyDir: {}}]
---
apiVersion: v1
kind: Service
metadata: {name: web}
spec:
  selector: {app.kubernetes.io/name: web}
  ports: [{name: http, port: 80, targetPort: http}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: web}
spec:
  parentRefs: [{name: public, namespace: gateway}]
  hostnames: [app.example.com]
  rules: [{backendRefs: [{name: web, port: 80}]}]
```

No CPU limit is deliberate: CPU limits throttle bursty services, while a memory limit is
what prevents a noisy neighbour. Add a PodDisruptionBudget and an HPA for anything with
more than one replica ([k8s-manifests.md](references/k8s-manifests.md)).

## Debugging pods

```bash
kubectl get pods -o wide
kubectl describe pod <pod>                    # Events at the bottom say why
kubectl logs <pod> -c <container> --previous  # the crashed run, not the restarted one
kubectl get events --sort-by=.lastTimestamp -n <ns>
kubectl debug -it <pod> --image=busybox:1.37 --target=<container>   # ephemeral container, no restart
```

| Status | Usually | Look at |
|---|---|---|
| `Pending` | no node fits (requests too big, taints, affinity, an unbound PVC) | `describe pod` events |
| `ImagePullBackOff` | wrong tag, a private registry without `imagePullSecrets`, or a platform the node lacks | the exact image; `check-image-tags.py --live` (docker-ops) |
| `CrashLoopBackOff` | the app exits; a liveness probe kills it before it's up | `logs --previous`; add a `startupProbe` |
| `OOMKilled` (exit 137) | memory limit below real usage | `kubectl top pod`; raise the limit or fix the leak |
| `CreateContainerConfigError` | a missing Secret or ConfigMap key | `describe pod` |
| Running but no traffic | readiness failing, or the Service selector doesn't match the pod labels | `kubectl get endpointslices -l kubernetes.io/service-name=<svc>` |

## References

| File | Read when |
|---|---|
| [k8s-manifests.md](references/k8s-manifests.md) | Writing manifests: config, secrets, autoscaling, disruption budgets, NetworkPolicy, RBAC, Jobs |
| [helm-patterns.md](references/helm-patterns.md) | Writing or upgrading charts; moving to Helm 4 |
| [gateway-api.md](references/gateway-api.md) | Routing and TLS with Gateway API; migrating off ingress-nginx |
| [ecs-fargate.md](references/ecs-fargate.md) | Choosing ECS on Fargate vs Kubernetes; the ECS basics before AWS's own skill |
