# gitops-homelab

GitOps repo synced by ArgoCD running on a single-node bare-metal microk8s cluster.

## Host state (not tracked by Git — lives only on the box)

- microk8s channel: `1.35/stable` (v1.35.6)
- Addons enabled: `dns`, `helm3`, `hostpath-storage`, `metallb:192.168.1.240-192.168.1.250`, `nvidia` (GPU, `--driver host` / `--gpu-operator-driver host`)
- GPU: NVIDIA GTX 1060 6GB, host driver 580.159.03, CUDA 13.0
- ArgoCD installed in the `argocd` namespace, exposed via MetalLB LoadBalancer
- MetalLB pool: `192.168.1.240-192.168.1.250` (LAN `192.168.1.0/24`) — reserve this range in the router's DHCP settings

## Bootstrap (one-time, imperative)

```bash
sudo microk8s kubectl apply -f bootstrap/root-app.yaml
```

This creates the `root` Application (app-of-apps), which then auto-discovers and syncs everything under `apps/`. After this, all changes are made via Git commits — no more imperative `kubectl apply`.

## Structure

- `bootstrap/root-app.yaml` — the app-of-apps root, applied once
- `apps/ollama/application.yaml` — Ollama deployment (Helm chart `otwld/ollama-helm`). The served model is set in `spec.source.helm.valuesObject.ollama.models.pull` — edit and commit to bump the model version.

## Operational notes

- Model storage is a PVC (`microk8s-hostpath`, capped at 40Gi) — pod restarts do not re-download already-pulled models. The chart does not auto-remove stale model tags; prune manually if disk fills up.
- No public ingress — ArgoCD syncs via its default ~3 min polling interval (no GitHub webhook possible from a local-only network). Force an immediate sync with `argocd app sync <name>` if needed.
