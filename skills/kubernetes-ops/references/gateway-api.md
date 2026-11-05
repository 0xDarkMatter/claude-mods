# Gateway API and Leaving ingress-nginx

Gateway API is Kubernetes' routing API: Gateway v1.6 (Standard channel) as of 2026-10.
ingress-nginx, the controller behind most `Ingress` objects, was retired. This file covers
the replacement and the move.

## Contents

- [What happened to ingress-nginx](#what-happened-to-ingress-nginx)
- [The model: who owns what](#the-model-who-owns-what)
- [Resources and their maturity](#resources-and-their-maturity)
- [A route with TLS](#a-route-with-tls)
- [Common ingress-nginx annotations, translated](#common-ingress-nginx-annotations-translated)
- [Migrating](#migrating)
- [Installing the CRDs safely](#installing-the-crds-safely)

## What happened to ingress-nginx

- Kubernetes SIG Network and the Security Response Committee announced the retirement on
  2025-11-11. Maintenance was best-effort until March 2026. The final releases (controller
  v1.15.1 and v1.14.5, chart 4.15.1) shipped on 2026-03-19, and the repository is archived.
- **No further releases, bug fixes or security fixes.** Existing installs keep running and
  the install artefacts stay downloadable. That is the trap: it works until a CVE lands
  and nothing patches it.
- InGate, the planned successor, was retired as well. Move to Gateway API with an
  implementation you choose (Envoy Gateway, Istio, Cilium, NGINX Gateway Fabric, Traefik,
  a cloud provider's controller), or to another maintained Ingress controller.

## The model: who owns what

| Resource | Owned by | Says |
|---|---|---|
| `GatewayClass` | the platform team | which implementation (controller) handles Gateways of this class |
| `Gateway` | the platform team | the listeners: ports, protocols, hostnames, TLS certificates, which namespaces may attach routes |
| `HTTPRoute` / `GRPCRoute` / ... | each app team, in its own namespace | how requests for its hostnames reach its Services |
| `ReferenceGrant` | the target namespace | permission for a route or Gateway in another namespace to reference its objects |

The split is the point: app teams change routes without touching the shared Gateway, and
the Gateway decides which namespaces may attach (`allowedRoutes`).

## Resources and their maturity

| Resource | Standard (GA) since |
|---|---|
| GatewayClass, Gateway, HTTPRoute | v1.0 |
| GRPCRoute | v1.1 |
| BackendTLSPolicy | v1.4 |
| TLSRoute, ListenerSet, ReferenceGrant v1 | v1.5 |
| TCPRoute, UDPRoute (v1; their v1alpha2 versions are deprecated) | v1.6 |

Experimental-channel resources need `kubectl apply --server-side` to install. Check what
your implementation supports: conformance differs by vendor.

## A route with TLS

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: public, namespace: gateway}
spec:
  gatewayClassName: envoy            # your implementation's class
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      hostname: "*.example.com"
      tls: {mode: Terminate, certificateRefs: [{name: wildcard-example-com}]}
      allowedRoutes: {namespaces: {from: Selector, selector: {matchLabels: {gateway-access: "true"}}}}
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes: {namespaces: {from: Same}}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: https-redirect, namespace: gateway}
spec:
  parentRefs: [{name: public, sectionName: http}]
  rules: [{filters: [{type: RequestRedirect, requestRedirect: {scheme: https, statusCode: 301}}]}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: web, namespace: shop}             # shop carries the label gateway-access: "true"
spec:
  parentRefs: [{name: public, namespace: gateway, sectionName: https}]
  hostnames: [shop.example.com]
  rules:
    - matches: [{path: {type: PathPrefix, value: /api}}]
      backendRefs: [{name: api, port: 80}]
    - backendRefs: [{name: web, port: 80}]
```

cert-manager issues the certificate. Annotate the Gateway with
`cert-manager.io/cluster-issuer: <issuer>`, and cert-manager creates the Secret the listener
names (with Gateway API support enabled in cert-manager).

`kubectl get gateway,httproute -A` and `kubectl describe httproute web -n shop` show each
route's `Accepted` and `ResolvedRefs` conditions. A route that "does nothing" is almost
always one of those being False.

## Common ingress-nginx annotations, translated

| ingress-nginx annotation | Gateway API |
|---|---|
| `ssl-redirect: "true"` | an HTTP listener with a `RequestRedirect` filter (above) |
| `rewrite-target: /` | `URLRewrite` filter, `path: {type: ReplacePrefixMatch, replacePrefixMatch: /}` |
| `use-regex` | `path: {type: RegularExpression}` (implementation-specific) |
| `canary-weight` | `backendRefs` with `weight:` on each backend |
| `proxy-body-size`, timeouts, rate limits | not in the core API: the implementation's own policy resources (e.g. Envoy Gateway's `BackendTrafficPolicy`); HTTPRoute `timeouts` covers request timeouts |
| `auth-url` (external auth) | implementation policy resources |
| `whitelist-source-range` | implementation policy, or a NetworkPolicy at the Service |

Snippet annotations (`configuration-snippet`, `server-snippet`) have no portable
equivalent, and they were a long-running ingress-nginx security risk. Each one needs a
deliberate replacement.

## Migrating

1. Install a Gateway API implementation alongside ingress-nginx. Don't remove anything yet.
2. Convert the Ingress objects with Ingress2Gateway (1.0, March 2026). It reads Ingress
   objects plus common ingress-nginx annotations and emits Gateway and HTTPRoute YAML.
   Diff its output against the annotations you actually use: any it can't translate need
   a manual equivalent from the table above.
3. Apply the routes to the new Gateway under a test hostname, or point a canary DNS name at
   the new load balancer. Compare behaviour (redirects, rewrites, headers, body size).
4. Move DNS. Keep ingress-nginx running until traffic to it reaches zero.
5. Remove ingress-nginx and its Ingress objects (Tier 2: list them, confirm), then the CRDs
   and webhook it installed.

## Installing the CRDs safely

- Install the Standard channel unless you need an experimental resource. Mixing channels
  across teams is how CRDs get downgraded.
- Since v1.5, a `safe-upgrades` ValidatingAdmissionPolicy blocks installing Experimental
  CRDs over Standard ones, and blocks downgrades below 1.5.
- Many implementations bundle the CRDs in their Helm chart. Let exactly one thing own them.
