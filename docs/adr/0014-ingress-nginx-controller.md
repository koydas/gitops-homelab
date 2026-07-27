# ADR-0014: Add ingress-nginx as a Host-Routed Entry Point, Still LAN-Only

**Date:** 2026-07-27
**Status:** Accepted

---

## Context

[ADR-0002](./0002-lan-only-exposure.md) deliberately rejected an ingress controller: with only ArgoCD and Ollama, a dedicated `Service: LoadBalancer` per app on the MetalLB pool (`192.168.1.240-192.168.1.250`, 11 addresses — see [ADR-0008](./0008-metallb-config-in-git.md)) was simpler than standing up ingress infrastructure for no immediate benefit.

That reasoning was specific to "two services." The operator now plans to host multiple additional repos/apps on this cluster over time, not just Ollama. At one MetalLB IP per app, 3 are already spent (ArgoCD `.240`, Ollama `.241`, Grafana `.242` — see [ADR-0012](./0012-monitoring-stack.md)), leaving 8. Hosting several more HTTP-facing apps the same way would burn through the pool and give each one a bare IP with no hostname-based routing, revisiting the same namespace-per-workload pattern used for `apps/ollama` and `apps/monitoring` but for HTTP services specifically.

---

## Decision

Deploy the `ingress-nginx` Helm chart (`apps/ingress-nginx/application.yaml`, chart `4.15.1` from `https://kubernetes.github.io/ingress-nginx`, the current latest stable release per the chart repo's `index.yaml`) as an ArgoCD-managed workload app, same pattern as Ollama/monitoring: `project: homelab`, `CreateNamespace=true`, automated sync.

The controller's own `Service` is `type: LoadBalancer`, pinned to `192.168.1.243` via the `metallb.io/loadBalancerIPs` annotation (verified against MetalLB v0.15.2, which is what's actually running — see [runbook.md](../runbook.md)) rather than left to `autoAssign`, since this is meant to be one stable address that every future host-routed app's DNS/hosts entry points at; it shouldn't shift if the Service is ever recreated. `ingressClassResource.default: true` makes it the implicit `IngressClass` so future `Ingress` objects don't need to name it explicitly.

This **amends but does not reverse** ADR-0002: still no public domain, no cert-manager, no exposure past the home LAN. Only the internal routing model changes — future HTTP apps get an `Ingress` object routed by hostname through `.243`, instead of their own dedicated MetalLB IP. Non-HTTP workloads (Ollama's raw API, anything not naturally host-routable) keep using a dedicated `LoadBalancer` Service as before.

`apps/appproject.yaml` was updated to allow the new source repo and `ingress-nginx` destination namespace (per the guard rail described in [ADR-0007](./0007-dedicated-appproject.md)), plus `networking.k8s.io/IngressClass` added to `clusterResourceWhitelist` since the chart creates one cluster-scoped `IngressClass` resource — confirmed this is the only cluster-scoped kind the chart adds beyond what monitoring's whitelist entries already cover (no CRDs, unlike kube-prometheus-stack).

---

## Considered Alternatives

### Keep one MetalLB IP per app (status quo)
Simplest, and was fine for 2 services. Rejected once "several more apps" became the actual stated goal — doesn't scale past the 8 remaining pool addresses, and gives no hostname-based routing (every app is `http://<ip>:<port>`, not `http://<name>.home/`).

### Ingress + cert-manager + TLS now
Considered since ingress and TLS are often adopted together. Deferred, not rejected outright — no public domain or certificate need yet (still LAN-only per ADR-0002), and adding cert-manager only makes sense once there's an actual app that benefits from HTTPS internally (e.g. something handling credentials). Revisit when the first real app is onboarded behind this ingress.

### microk8s `ingress` addon (bundled nginx ingress) instead of the upstream Helm chart
Would avoid managing chart version/values directly, but the addon is enabled imperatively on the host (`microk8s enable ingress`), not Git-managed — inconsistent with every other workload in this repo being ArgoCD-synced from `apps/`. Rejected for the same reason ADR-0001 chose GitOps over ad hoc host commands generally.

---

## Consequences

**Good:**
- Future HTTP-facing apps route through one stable IP (`.243`) by hostname, instead of consuming a fresh MetalLB address each — the pool stops being the limiting factor for "how many apps can this cluster host."
- Fits the existing GitOps pattern exactly (`apps/<name>/application.yaml` + `appproject.yaml` destination entry) — no new mental model for how workloads get added.

**Neutral:**
- Apps that aren't naturally HTTP/host-routable (like Ollama's API, kept as-is) still get their own dedicated `LoadBalancer` IP — this doesn't replace that pattern, it adds a second one alongside it.
- Hostnames for future apps behind this ingress will need local resolution (`/etc/hosts` entries or a LAN DNS entry pointing at `.243`) since there's no DNS server in this environment yet — not a blocker, just a per-app setup step when the first one is added.

**Negative:**
- One more Application to keep Synced/Healthy; if it ever goes down, every app routed through it becomes unreachable at once (a shared failure point that per-app dedicated IPs didn't have).
