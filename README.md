# gitops-homelab

[![validate](https://github.com/koydas/gitops-homelab/actions/workflows/validate.yml/badge.svg)](https://github.com/koydas/gitops-homelab/actions/workflows/validate.yml)

GitOps repo synced by ArgoCD running on a single-node bare-metal microk8s cluster.

## Documentation

- [docs/architecture.md](./docs/architecture.md) — components, data flow, what lives where
- [docs/runbook.md](./docs/runbook.md) — operational tasks and troubleshooting (real incidents, not hypothetical)
- [docs/testing.md](./docs/testing.md) — verification checklist and the Postman collection
- [docs/adr/](./docs/adr/README.md) — Architecture Decision Records: what was decided, alternatives considered, why

## Host state (not tracked by Git — lives only on the box)

- microk8s channel: `1.35/stable` (v1.35.6)
- Addons enabled: `dns`, `helm3`, `hostpath-storage`, `metallb:192.168.1.240-192.168.1.250`, `nvidia` (GPU, `--driver host` / `--gpu-operator-driver host`)
- GPU: NVIDIA GTX 1060 6GB, host driver 580.159.03, CUDA 13.0 (pre-existing on the host — the GPU addon uses it as-is, it does not install/build its own driver)
- ArgoCD installed in the `argocd` namespace, exposed via MetalLB LoadBalancer
- MetalLB pool: `192.168.1.240-192.168.1.250` (LAN `192.168.1.0/24`) — reserve this range in the router's DHCP settings

These values are the *current* ones for this specific box; `bootstrap/install-host.sh` is the executable source of truth for how to (re)produce this layer — see below.

## Recreate from scratch

On a fresh Ubuntu box with a working NVIDIA driver already installed (this repo does not install/manage the host GPU driver itself):

```bash
git clone https://github.com/koydas/gitops-homelab.git
cd gitops-homelab
METALLB_RANGE=192.168.1.240-192.168.1.250 ./bootstrap/install-host.sh
sudo microk8s kubectl apply -f bootstrap/root-app.yaml
```

`install-host.sh` installs microk8s, enables the required addons, enables GPU support, and installs + exposes ArgoCD — idempotent, safe to re-run. It encodes two gotchas hit while building this the first time, so they don't have to be rediscovered:
- refuses to proceed if an apt-installed `containerd` package is present (known root cause of the GPU addon hanging in `Init`: canonical/microk8s#5229)
- applies the ArgoCD manifest with `--server-side --force-conflicts` (plain `kubectl apply` fails on the `applicationsets.argoproj.io` CRD — its annotation exceeds kubectl's client-side size limit)

Applying `bootstrap/root-app.yaml` creates the `root` Application (app-of-apps), which then auto-discovers and syncs everything under `apps/`. After this, all changes are made via Git commits — no more imperative `kubectl apply`.

**The `monitoring` Application needs two manual, one-time steps** that `root`'s own sync cannot do for itself (see [ADR-0012](./docs/adr/0012-monitoring-stack.md) and [runbook.md](./docs/runbook.md) for why each is a hard requirement, not a nice-to-have):

1. **Create the Grafana admin credentials Secret before (or right after) the first sync** — the chart is configured with `grafana.admin.existingSecret`, so it will not boot without it:
   ```bash
   sudo microk8s kubectl create namespace monitoring
   sudo microk8s kubectl -n monitoring create secret generic grafana-admin-credentials \
     --from-literal=admin-user=admin \
     --from-literal=admin-password="$(python3 -c 'import secrets; print(secrets.token_urlsafe(30))')"
   ```
2. **Install `kube-prometheus-stack`'s CRDs by hand, server-side, once** — its largest CRDs exceed Kubernetes' 262144-byte `last-applied-configuration` annotation limit under a plain apply, and ArgoCD does not reliably self-heal past that on a chart's own `crds/` directory:
   ```bash
   curl -sL -o /tmp/kps.tgz "https://github.com/prometheus-community/helm-charts/releases/download/kube-prometheus-stack-87.19.1/kube-prometheus-stack-87.19.1.tgz"
   tar xzf /tmp/kps.tgz -C /tmp kube-prometheus-stack/charts/crds/crds/
   sudo microk8s kubectl apply --server-side --force-conflicts -f /tmp/kube-prometheus-stack/charts/crds/crds/
   ```
   Bump the chart version in that URL if `apps/monitoring/application.yaml`'s `targetRevision` has moved on since this was written.

Do both *before* `root`'s first sync reaches `monitoring` if possible — if `root`'s sync gets stuck retrying on a missing `ServiceMonitor` CRD or a missing Grafana secret, force a refresh (`argocd.argoproj.io/refresh=hard` on `root`, not `monitoring`) once both are in place.

**What does *not* come back automatically:**
- Ollama model blobs — they re-download from scratch on first sync (currently ~9GB across 3 models); nothing in Git stores model weights.
- The ArgoCD admin password — regenerated fresh on install; fetch it from `install-host.sh`'s output or `argocd-initial-admin-secret`.
- Prometheus's metrics history and Grafana's own PVC — both start empty; GPU/cluster metrics history from before the rebuild is gone.
- The `grafana-admin-credentials` Secret — must be recreated per the steps above; it is deliberately not chart-generated (see ADR-0012), so nothing will conjure it automatically.
- The MetalLB range must still be manually reserved in the router's DHCP settings — the script does not, and cannot, touch your router.
- Anything under "Host state" above that's specific to *this* box (GPU model, driver version) — adjust `install-host.sh` env vars / the GPU addon flags if the target hardware differs.

## Structure

- `bootstrap/install-host.sh` — rebuilds the host layer this repo depends on (microk8s, addons, GPU, ArgoCD). Run once per fresh box.
- `bootstrap/root-app.yaml` — the app-of-apps root, applied once after `install-host.sh`
- `apps/appproject.yaml` — `homelab` AppProject; workload Applications (e.g. `ollama`) are scoped to it instead of `default`. Add a `destinations` entry here for each new namespace a future app needs. Carries `sync-wave: "-1"` so ArgoCD creates it before the Applications that reference it.
- `apps/ollama/application.yaml` — Ollama deployment (Helm chart `otwld/ollama-helm`), project `homelab`. The served model is set in `spec.source.helm.valuesObject.ollama.models.pull` — edit and commit to bump the model version.
- `apps/monitoring/` — Prometheus + Grafana (Helm chart `prometheus-community/kube-prometheus-stack`), project `homelab`. `application.yaml` is the chart Application; `dcgm-servicemonitor.yaml` and `dcgm-dashboard-configmap.yaml` are plain manifests (not chart-templated) that wire up GPU scraping and the Grafana dashboard. See [ADR-0012](./docs/adr/0012-monitoring-stack.md) — this one needs manual one-time bootstrap steps, see "Recreate from scratch" above.
- `apps/metallb-config/` — `IPAddressPool` + `L2Advertisement`, Git-managed (the `metallb` addon still installs the MetalLB controller itself; these manifests take over ownership of the address pool it creates so the LAN IP range is changeable via a Git commit instead of only via `microk8s enable metallb:<range>` on the host). Names match the addon's originally-created objects so ArgoCD adopts them in place.
- `postman/ollama.postman_collection.json` — Postman collection for smoke-testing the Ollama API (`/api/tags`, `/api/generate`, `/api/chat`, `/api/embed`, a code-generation prompt against the coder model). Not synced by ArgoCD, just kept alongside the infra it tests. Import into Postman and set `base_url` to the Ollama Service's MetalLB IP if it ever changes.
- `docs/` — architecture, runbook, testing checklist, and ADRs. See [Documentation](#documentation) above.

## CI

`.github/workflows/validate.yml` runs on every push/PR: `yamllint` for syntax, `kubeconform` (against the `datreeio/CRDs-catalog` schemas) to validate `Application`, `AppProject`, `IPAddressPool`, and `L2Advertisement` manifests before ArgoCD ever sees them.

## Operational notes

- Model storage is a PVC (`microk8s-hostpath`, capped at 40Gi) — pod restarts do not re-download already-pulled models. The chart does not auto-remove stale model tags; prune manually if disk fills up.
- No public ingress — ArgoCD syncs via its default ~3 min polling interval (no GitHub webhook possible from a local-only network). Force an immediate sync with:
  ```bash
  sudo microk8s kubectl -n argocd annotate application <name> argocd.argoproj.io/refresh=hard --overwrite
  ```
- Changing the MetalLB range: edit `apps/metallb-config/ipaddresspool.yaml`, commit, push. Reserve the new range in the router's DHCP settings first.
- GPU/cluster metrics: Grafana at `192.168.1.242` (see [runbook.md](./docs/runbook.md) for the admin password), 15 days of Prometheus history. See [ADR-0012](./docs/adr/0012-monitoring-stack.md).
- **Forcing a sync after editing a *child* Application file** (e.g. `apps/monitoring/application.yaml`, `apps/ollama/application.yaml`) — refresh-annotate `root`, not the child app by name. The child Application's own YAML is itself a Git-tracked resource owned by `root`'s sync; refreshing the child only re-evaluates its already-live spec against the Helm chart, it does not pull your latest edit to that spec from Git.
