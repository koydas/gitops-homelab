# ADR-0015: Onboard `ollama-chat` as a Git-source Application, not a Helm chart

**Date:** 2026-07-28
**Status:** Accepted

---

## Context

Every workload Application onboarded so far (Ollama, kube-prometheus-stack, ingress-nginx)
sources from a public Helm chart repo (`spec.source.chart` + `repoURL`). `koydas/ollama-chat`
is a custom app with no chart — a Node/Vite frontend with an Express backend, built from a
`Dockerfile` and deployed via plain Kustomize manifests that live in that repo's own `k8s/`
directory (see `ollama-chat`'s ADR-0006 for why the manifests and image-publishing pipeline
live there rather than here).

## Decision

`apps/ollama-chat/application.yaml` uses a **git source** instead of a chart source:

```yaml
source:
  repoURL: https://github.com/koydas/ollama-chat.git
  targetRevision: main
  path: k8s
```

Same `project: homelab`, same `syncPolicy.automated: { prune: true, selfHeal: true }` and
`CreateNamespace=true` as every other Application here — only the source type differs.
`apps/appproject.yaml` gets `https://github.com/koydas/ollama-chat.git` added to
`sourceRepos` and `ollama-chat` added to `destinations`, per the guard rail in ADR-0007.
No `clusterResourceWhitelist` change was needed: unlike kube-prometheus-stack or
ingress-nginx, `ollama-chat`'s manifests (Deployment, Service, Ingress, PVC) are all
namespace-scoped.

`ollama-chat` is routed through `ingress-nginx` (ADR-0014) at hostname `ollama-chat.home`
rather than getting its own MetalLB IP — the first app to actually use the path ADR-0014
anticipated.

## Alternatives Considered

- **Vendor a Helm chart for `ollama-chat` into this repo** — rejected: would mean
  maintaining chart boilerplate (templates, values schema) for a single-image app with four
  flat manifests; Kustomize in the app's own repo is simpler and keeps the deployment shape
  next to the code it deploys.
- **Copy `ollama-chat`'s manifests into this repo under `apps/ollama-chat/`** — rejected, see
  `ollama-chat` ADR-0006: would split one app's deployment definition across two repos for no
  benefit, and require this repo to be touched for changes that only affect `ollama-chat`
  (resource limits, env vars, ingress host).

## Consequences

**Good:**
- First proof that this repo's Application/AppProject pattern generalizes to non-Helm,
  custom-built apps — future homegrown services follow the same recipe (git source +
  `path`, project `homelab`, an `apps/<name>/application.yaml` here that just points at them).

**Neutral:**
- Two repos now matter for "is `ollama-chat` deployed correctly": this one for the
  Application/AppProject wiring, `ollama-chat` itself for the manifests and image pipeline.
  Consistent with how Ollama's chart values already split "what version/config" (here) from
  "what the chart does" (upstream `otwld/ollama-helm`), just with a repo `koydas` also owns.

**Negative:**
- ArgoCD's ~3min poll interval (ADR-0002 — no webhook, no public ingress) applies to this
  second repo too; a new `ollama-chat` image can take up to that long to show as `OutOfSync`
  after its CI pushes the tag-bump commit.
