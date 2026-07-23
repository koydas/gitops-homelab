# ADR-0001: Kubernetes (microk8s) + ArgoCD for GitOps, Not Plain Docker

**Date:** 2026-07-23  
**Status:** Accepted

---

## Context

This is a fresh bare-metal Ubuntu 26.04 install intended to host self-hosted services and local LLM agents. The first architectural fork was container orchestration: run services directly under Docker (the simplest path for a single box), or run Kubernetes with a GitOps controller on top.

The deciding requirement, stated directly by the operator: the ability to change which LLM model is served by editing a file and committing it to Git, with the change rolling out automatically — not by SSHing in and running `ollama pull` by hand.

---

## Decision

Use **microk8s** (single-node) with **ArgoCD** as the GitOps controller. Docker alone was explicitly ruled out once GitOps was named as the goal — Docker has no native concept of declarative, Git-driven reconciliation; achieving the same outcome on top of plain Docker would mean building an ad hoc polling/deploy script, which is exactly what ArgoCD already is, hardened and maintained.

---

## Considered Alternatives

This choice was made directly by the operator rather than evaluated against a wider field (e.g. k3s, k0s, kubeadm as alternative Kubernetes distributions; Flux as an alternative GitOps controller). microk8s was picked for being a single-command install with first-class addons for exactly what this box needs (hostpath storage, MetalLB, NVIDIA GPU support) without assembling them from separate projects.

### Docker only, no orchestrator
Rejected once GitOps was named as a hard requirement (see Context) — Docker Compose has no built-in reconciliation loop against a Git source of truth.

---

## Consequences

**Good:**
- Model version changes (and any future service changes) are a single Git commit away, with automatic rollout — the core requirement.
- microk8s's addon system (`hostpath-storage`, `metallb`, `gpu`) covers everything this single-node box needs without separately installing/configuring each component.

**Neutral:**
- Kubernetes is meaningfully more operational surface than Docker for a single box hosting one real workload (Ollama). Accepted as the cost of the GitOps requirement.

**Negative:**
- Debugging is one layer deeper (pod → container vs. just container) — e.g. the `ContainerCreating` / kubelet-lag incident in [runbook.md](../runbook.md) would not exist under plain Docker.
