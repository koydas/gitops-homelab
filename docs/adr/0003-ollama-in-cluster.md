# ADR-0003: Ollama Deployed In-Cluster, Not as a Bare-Metal Install

**Date:** 2026-07-23  
**Status:** Accepted

---

## Context

With Kubernetes + ArgoCD chosen for GitOps ([ADR-0001](./0001-kubernetes-gitops-over-docker.md)), the LLM runtime itself could still go either way: run Ollama natively on the host (simplest, no GPU-passthrough complexity) or run it as a pod inside microk8s (consistent with the rest of the GitOps-managed stack, but requires the cluster to expose the GPU to pods).

---

## Decision

Run Ollama **in-cluster**, as a containerized ArgoCD Application, with the GPU exposed to it via microk8s's `nvidia` addon (`--driver host`, reusing the already-installed 580.159.03 driver rather than having the addon install its own).

The deciding factor: with only one GPU on this box, there is no multi-tenancy/isolation benefit to containerizing Ollama — the choice came down entirely to "does the model version live under Git control." A bare-metal install would mean the served model is host state, invisible to and unchangeable from the Git repo; a pod means `models.pull` in `apps/ollama/application.yaml` is the single source of truth.

---

## Considered Alternatives

### Bare-metal Ollama install on the host
Simpler — no GPU-passthrough layer (device plugin, container toolkit, `runtimeClassName`), no PVC. Rejected because it would put the served model outside Git's reach, defeating the core requirement from [ADR-0001](./0001-kubernetes-gitops-over-docker.md) ("bump the model via a Git commit").

---

## Consequences

**Good:**
- Model version is Git-tracked and change-controlled like everything else in this repo (validated live: see [ADR-0004](./0004-ollama-helm-deployment.md) and the model-bump test in [testing.md](../testing.md)).
- Pod restarts don't lose downloaded models — they're on a PVC, not container-ephemeral storage.

**Neutral:**
- GPU passthrough works today via microk8s's `nvidia` addon with `--driver host`, but this is one more moving part than a bare install would have. `docs/runbook.md` documents the GPU-addon gotcha this surfaced.

**Negative:**
- One layer of indirection added to debugging (see the `ContainerCreating` kubelet-lag incident in [runbook.md](../runbook.md), which would not exist with a bare-metal install).
- Ollama's CUDA v13-targeted binaries explicitly skip the GTX 1060 (`compute capability not in compiled architectures`) and fall back to a bundled CUDA v12 path — works today, but is a live illustration of the Pascal-generation legacy-driver risk that a containerized runtime inherits from the host driver. Documented in [runbook.md](../runbook.md).
