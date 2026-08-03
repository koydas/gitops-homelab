# ADR-0023: Onboard `healing-simulator` as a git-source Application

**Date:** 2026-08-03
**Status:** Accepted

---

## Context

`koydas/healing-simulator` is a static React/Vite mobile web game (a WoW
Classic-inspired healer simulator) with no backend and no persistence — a
Dockerfile builds it into a non-root Nginx image, and the repo carries its own
`k8s/` (Deployment, Service, Ingress). This is the same shape `ollama-chat`
already onboarded in (ADR-0015): a custom app with no Helm chart, built and
published from its own repo rather than from manifests vendored here.

## Decision

`apps/healing-simulator/application.yaml` uses a **git source**, same recipe
as ADR-0015:

```yaml
source:
  repoURL: https://github.com/koydas/healing-simulator.git
  targetRevision: main
  path: k8s
```

Same `project: homelab`, `syncPolicy.automated: { prune: true, selfHeal: true }`
and `CreateNamespace=true` as every other Application here. `apps/appproject.yaml`
gets `https://github.com/koydas/healing-simulator.git` added to `sourceRepos`
and `healing-simulator` added to `destinations` (ADR-0007's guard rail). No
`clusterResourceWhitelist` change needed: the app's manifests (Deployment,
Service, Ingress) are all namespace-scoped.

`healing-simulator`'s own repo carries a `docker-publish.yml` workflow
(mirroring `ollama-chat`'s) that builds the image, pushes it to
`ghcr.io/koydas/healing-simulator`, and commits the built tag back into its
`k8s/deployment.yaml` — that commit is what this Application syncs on. Per
ADR-0018, the GHCR package must be set to public visibility (no
`imagePullSecret` is carried in the Deployment) or the pod sits in
`ImagePullBackOff` with no obvious reason why.

The app is routed through `ingress-nginx` (ADR-0014) at hostname
`healing-simulator.home`, not a dedicated MetalLB IP — same reasoning as
`ollama-chat`: no realtime backend, no reason to need its own IP.

## Alternatives Considered

- **Copy the manifests into this repo under `apps/healing-simulator/`** —
  rejected, same reasoning as ADR-0015: splits one app's deployment
  definition across two repos, and requires this repo to be touched for
  changes that only affect `healing-simulator` (resource limits, ingress
  host).
- **A dedicated MetalLB IP** — rejected: the app is a static SPA with no
  websocket/streaming traffic pattern that would benefit from bypassing the
  shared ingress; `ingress-nginx` already fronts `ollama-chat` the same way.

## Consequences

**Good:**
- Second confirmation (after `ollama-chat`) that the git-source
  Application pattern generalizes cleanly to homegrown, non-Helm apps.

**Neutral:**
- Two repos matter for "is `healing-simulator` deployed correctly": this one
  for the Application/AppProject wiring, `healing-simulator` itself for the
  manifests and image pipeline (see that repo's ADR-0012).

**Negative:**
- ArgoCD's ~3min poll interval (ADR-0002) applies to this repo too; a new
  `healing-simulator` image can take up to that long to show as `OutOfSync`
  after its CI pushes the tag-bump commit, unless refreshed manually.
