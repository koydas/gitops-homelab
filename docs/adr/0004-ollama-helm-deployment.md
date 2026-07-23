# ADR-0004: Ollama Deployed via the `otwld/ollama-helm` Chart, Referenced Directly

**Date:** 2026-07-23  
**Status:** Accepted

---

## Context

With Ollama running in-cluster ([ADR-0003](./0003-ollama-in-cluster.md)), it needs a Deployment, a Service, a PVC, GPU resource requests, and a mechanism to pull specific model tags at startup. This could be hand-written as plain Kubernetes manifests (optionally templated with Kustomize), or delegated to an existing Helm chart.

---

## Decision

Use the community **`otwld/ollama-helm`** chart, referenced directly by the ArgoCD `Application` (`repoURL: https://helm.otwld.com/`, no vendoring/forking), with the entire configuration — including which models are served — inlined as `spec.source.helm.valuesObject` in `apps/ollama/application.yaml`. This makes the whole app, model version included, a single Git-tracked YAML file.

The chart was verified live before adopting it: pulled its `values.yaml` at the pinned version (`1.68.0`) to confirm the exact field names (`ollama.gpu.*`, `ollama.models.pull`, `persistentVolume.*`, top-level `runtimeClassName` and `service`) rather than guessing from documentation.

---

## Considered Alternatives

### Hand-written plain manifests (Deployment + Service + PVC), optionally via Kustomize
This is a single small deployment, not a fleet needing multi-environment overlay layering — Kustomize's main value proposition doesn't apply here. Hand-writing the Deployment/PVC/GPU-request boilerplate would duplicate what the chart already provides (`models.pull` init behavior, GPU resource wiring, PVC templating) for no benefit.

---

## Consequences

**Good:**
- Bumping or adding a model is a one-line edit to `models.pull` — validated live twice (`qwen2.5:0.5b` added via the GitOps flow, then `qwen2.5-coder:7b-instruct-q4_0`).
- GPU wiring (`nvidia.com/gpu` resource request, `runtimeClassName`) and PVC-backed persistence come from the chart, not hand-maintained YAML.

**Neutral:**
- The chart's `models.pull` mechanism does not remove models no longer listed (`models.clean` defaults to `false` and was left disabled) — stale tags accumulate on the PVC until pruned manually. Documented in [runbook.md](../runbook.md).
- Chart version is pinned explicitly (`targetRevision: 1.68.0`) rather than tracking latest, so upgrades are deliberate.

**Negative:**
- Depends on an external chart repo (`helm.otwld.com`) staying available; if it disappears, `apps/ollama/application.yaml` stops resolving until re-pointed at a vendored copy.
