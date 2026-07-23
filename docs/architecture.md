# Architecture

Single-node bare-metal server running microk8s, GitOps-managed by ArgoCD, hosting a local LLM runtime (Ollama) with GPU acceleration.

## Components

```mermaid
flowchart TB
    subgraph gh["GitHub"]
        repo["koydas/gitops-homelab (public)"]
    end

    subgraph host["Bare-metal host (Ubuntu 26.04, GTX 1060 6GB)"]
        subgraph mk["microk8s (single node)"]
            argocd["ArgoCD\n(namespace: argocd)"]
            root["root Application\n(app-of-apps)"]
            proj["homelab AppProject"]
            ollama["ollama Application\n(namespace: ollama)"]
            mlb["metallb-config\n(IPAddressPool, L2Advertisement)"]
            pvc["PVC: ollama\n(40Gi, microk8s-hostpath)"]
        end
        metallb["MetalLB\n(192.168.1.240-250)"]
        gpu["NVIDIA GTX 1060\n(driver 580.159.03, host mode)"]
    end

    user["Operator (curl / Postman / browser)"]

    repo -- "poll ~3min / manual refresh" --> argocd
    argocd --> root
    root --> proj
    root --> ollama
    root --> mlb
    ollama -- "GPU passthrough" --> gpu
    ollama -- "model storage" --> pvc
    mlb --> metallb
    metallb -- "192.168.1.240" --> argocd
    metallb -- "192.168.1.241:11434" --> ollama
    user -- "https" --> metallb
    user -- "HTTP API" --> metallb
```

## What lives where

| Layer | Source of truth | Notes |
|---|---|---|
| Host OS, NVIDIA driver | Manual (imperative, pre-existing) | Not managed by this repo; assumed present before `bootstrap/install-host.sh` runs |
| microk8s + addons (dns, hostpath-storage, metallb, gpu) + ArgoCD install | `bootstrap/install-host.sh` | Idempotent script, source of truth for host-layer commands |
| ArgoCD `root` Application | `bootstrap/root-app.yaml`, applied once manually | Bootstraps everything below it |
| Workload apps (Ollama), AppProject, MetalLB IP pool | `apps/**` in this repo | Fully Git-managed; ArgoCD syncs automatically |
| Ollama model weights | PVC on host disk (`microk8s-hostpath`) | **Not** in Git — re-downloaded on a fresh PVC (see [runbook.md](./runbook.md)) |
| ArgoCD admin password | Kubernetes Secret, regenerated per install | Not in Git; rotate after first login |

## Request flow (Ollama inference)

1. Client (curl, Postman, or the `ollama` CLI pointed at `OLLAMA_HOST`) sends an HTTP request to `192.168.1.241:11434`.
2. MetalLB (L2 mode) routes it to the `ollama` Service, which forwards to the `ollama` Deployment's single pod.
3. The pod has `nvidia.com/gpu: 1` requested and `runtimeClassName: nvidia`, so inference runs on the GTX 1060 rather than falling back to CPU (see [ADR-0003](./adr/0003-ollama-in-cluster.md)).
4. Model weights are read from the PVC (`/root/.ollama`), which persists across pod restarts.

## GitOps sync flow (changing what's deployed)

1. Edit a manifest under `apps/` (e.g. bump `models.pull` in `apps/ollama/application.yaml`).
2. Commit and push to `main` on GitHub.
3. ArgoCD's `root` Application polls the repo (~3 min interval; no webhook is possible since there's no public ingress — see [ADR-0002](./adr/0002-lan-only-exposure.md)) and detects drift.
4. `syncPolicy.automated` (with `selfHeal: true`, `prune: true`) applies the change without manual intervention. A hard refresh can be forced with:
   ```bash
   sudo microk8s kubectl -n argocd annotate application <name> argocd.argoproj.io/refresh=hard --overwrite
   ```
