# ADR Index

Architecture Decision Records for `gitops-homelab`. Format follows [koydas/autonomous-dev-loop](https://github.com/koydas/autonomous-dev-loop/tree/main/docs/adr).

## Records

- [ADR-0001: Kubernetes (microk8s) + ArgoCD for GitOps, not plain Docker](./0001-kubernetes-gitops-over-docker.md)
- [ADR-0002: LAN-only exposure via MetalLB, no public ingress](./0002-lan-only-exposure.md)
- [ADR-0003: Ollama deployed in-cluster, not as a bare-metal install](./0003-ollama-in-cluster.md)
- [ADR-0004: Ollama deployed via the `otwld/ollama-helm` chart, referenced directly](./0004-ollama-helm-deployment.md)
- [ADR-0005: Pin microk8s to `1.35/stable`, overriding an initial `1.32` recommendation](./0005-microk8s-version-pin.md)
- [ADR-0006: GitOps repo kept public](./0006-public-repo-visibility.md)
- [ADR-0007: Dedicated `homelab` AppProject for workload apps](./0007-dedicated-appproject.md)
- [ADR-0008: MetalLB IP pool adopted into Git management](./0008-metallb-config-in-git.md)
- [ADR-0009: CI validates manifests statically, does not deploy to a test cluster](./0009-static-ci-validation.md)
- [ADR-0010: Full sudo access granted to the assistant session](./0010-assistant-sudo-access.md)
- [ADR-0011: Ollama models pinned to Q4_0 quantization, not Q5_K_M](./0011-ollama-q4-quantization.md)
- [ADR-0012: kube-prometheus-stack (full) for GPU monitoring, LoadBalancer-exposed, 15-day retention](./0012-monitoring-stack.md)
