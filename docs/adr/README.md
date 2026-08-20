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
- [ADR-0013: Ollama serves requests sequentially, no `OLLAMA_NUM_PARALLEL`](./0013-ollama-sequential-requests.md)
- [ADR-0014: Add ingress-nginx as a host-routed entry point, still LAN-only](./0014-ingress-nginx-controller.md)
- [ADR-0015: Onboard `ollama-chat` as a Git-source Application, not a Helm chart](./0015-ollama-chat-git-source-application.md)
- [ADR-0016: Onboard Whisper (STT) and Piper (TTS), CPU-only, split raw-manifest vs git-source](./0016-onboard-whisper-piper-cpu-only.md) — Whisper's CPU-only part superseded by ADR-0017
- [ADR-0017: Whisper moves to GPU via time-slicing, Ollama gets `OLLAMA_KEEP_ALIVE=30s`](./0017-whisper-gpu-with-keep-alive.md)
- [ADR-0018: GHCR images pulled via public package visibility, no `imagePullSecret` in Git](./0018-ghcr-public-visibility-no-pull-secret.md)
- [ADR-0019: Cap Ollama to one loaded model at a time (`OLLAMA_MAX_LOADED_MODELS=1`)](./0019-ollama-max-loaded-models-one.md)
- [ADR-0020: Onboard `homelab-gateway` as a git-source Application](./0020-onboard-homelab-gateway.md)
- [ADR-0021: Lower DCGM scrape interval from 30s to 10s](./0021-dcgm-scrape-interval-10s.md)
- [ADR-0022: Onboard `claude-code-runner` as a suspended CronJob template](./0022-onboard-claude-code-runner.md)
- [ADR-0023: Onboard `healing-simulator` as a git-source Application](./0023-onboard-healing-simulator.md)
- [ADR-0024: Onboard `jo-bines-adventures` as a git-source Application](./0024-onboard-jo-bines-adventures.md)
- [ADR-0025: Host-level auto-extend for root disk, with a Prometheus backstop alert](./0025-disk-space-auto-extend.md)
