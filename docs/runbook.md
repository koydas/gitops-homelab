# Operator Runbook

## Common Tasks

**Bump or add an Ollama model:**
```bash
# edit apps/ollama/application.yaml -> spec.source.helm.valuesObject.ollama.models.pull
git add apps/ollama/application.yaml
git commit -m "Add/bump model: <tag>"
git push
# optional: force an immediate sync instead of waiting ~3 min
sudo microk8s kubectl -n argocd annotate application ollama argocd.argoproj.io/refresh=hard --overwrite
```
Before committing a new tag, verify it actually exists — a typo produces a silent-until-sync failure, not a CI failure (see [ADR-0009](./adr/0009-static-ci-validation.md)):
```bash
curl -s -o /dev/null -w "%{http_code}\n" https://registry.ollama.ai/v2/library/<model>/manifests/<tag>
# 200 = exists, 404 = check spelling
```

**Force an ArgoCD sync for any app:**
```bash
sudo microk8s kubectl -n argocd annotate application <name> argocd.argoproj.io/refresh=hard --overwrite
```

**Check ArgoCD / Ollama status:**
```bash
sudo microk8s kubectl -n argocd get application -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
sudo microk8s kubectl -n ollama get pods,pvc,svc
```

**Confirm inference is actually running on the GPU (not falling back to CPU):**
```bash
curl -s http://192.168.1.241:11434/api/generate -d '{"model":"qwen2.5:0.5b","prompt":"hi","stream":false}' &
watch -n1 nvidia-smi   # VRAM usage and GPU-Util%% should spike during the request
```

**Rotate the ArgoCD admin password:** log into the UI (`https://192.168.1.240`) → user icon (top right) → *Update Password*. The initial auto-generated password is only ever shown once, via:
```bash
sudo microk8s kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

**Access Grafana / retrieve its admin password:** Grafana is exposed at `http://192.168.1.242` (MetalLB, `monitoring` Application — see [ADR-0012](./adr/0012-monitoring-stack.md)). Username is `admin`; the password is auto-generated on first install and only ever retrievable via:
```bash
sudo microk8s kubectl -n monitoring get secret -l app.kubernetes.io/name=grafana \
  -o jsonpath="{.items[0].data.admin-password}" | base64 -d
```

**Check that Prometheus is actually scraping the GPU exporter:**
```bash
sudo microk8s kubectl -n monitoring get servicemonitor nvidia-dcgm-exporter
# In the Prometheus UI (port-forward or via Grafana's Explore), Status > Targets should show
# nvidia-dcgm-exporter/0 as "UP":
sudo microk8s kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090
```

**Prune stale model tags** (the Helm chart's `models.clean` is left `false` — see [ADR-0004](./adr/0004-ollama-helm-deployment.md) — so removing a tag from `models.pull` does not delete it from the PVC):
```bash
sudo microk8s kubectl -n ollama exec deploy/ollama -- ollama rm <tag>
```

**Rebuild this server from scratch:** see [README.md § Recreate from scratch](../README.md#recreate-from-scratch).

---

## Incidents Hit While Building This

### `kubectl apply` fails with `metadata.annotations: Too long` on the ArgoCD install
**Cause:** the `applicationsets.argoproj.io` CRD's schema is large enough that the `kubectl.kubernetes.io/last-applied-configuration` annotation client-side `apply` writes exceeds Kubernetes' 262144-byte annotation limit.
**Fix:** use `--server-side --force-conflicts` instead of plain `apply` (already baked into `bootstrap/install-host.sh`).

### GPU addon pods stuck in `Init` forever
**Cause, per the upstream issue this project's driver/CUDA combo matches (canonical/microk8s#5229):** a separately apt-installed `containerd` package conflicting with microk8s's bundled one, not an inherent version bug. See [ADR-0005](./adr/0005-microk8s-version-pin.md) for the full root-cause writeup.
**Fix:** `dpkg -l | grep containerd` should be empty before enabling the `gpu`/`nvidia` addon; `bootstrap/install-host.sh` checks this automatically and refuses to proceed if it finds a conflict.

### A newly-rolled-out Ollama pod sits in `ContainerCreating` for 10+ minutes with no events in the namespace
**Observed:** during the `qwen2.5-coder` model rollout, the new pod showed `0/1 ContainerCreating` with `kubectl describe pod` reporting `Events: <none>`, while `containerd`'s own journal logs showed the container had actually started successfully (`StartContainer ... returns successfully`) within seconds.
**Likely cause:** a kubelet↔API-server event/status sync lag rather than a real failure — the kubelet journal around the same time showed `EndpointSlice informer cache is out of date` and `container event discarded` messages.
**Resolution:** self-resolved without intervention after several minutes; the pod's actual `status.phase` became `Running` once the sync caught up. No fix was applied.
**If it recurs:** check `sudo journalctl -u snap.microk8s.daemon-containerd -n 50` for `StartContainer ... returns successfully` before assuming the pod is genuinely stuck — the container may already be up despite what `kubectl get pods` reports.

### `curl: (7) Failed to connect ... No route to host` against the Ollama Service IP
**Cause:** the old pod had just been terminated (ArgoCD sync rolling out a new one) and the new pod hadn't yet become `Ready`, so the Service had zero healthy endpoints for a brief window.
**Fix:** none needed — wait for the new pod to reach `Running`/`Ready` (`kubectl -n ollama get pods -w`).

### `monitoring` Application stuck `SyncFailed` on several CRDs: `metadata.annotations: Too long`
**Cause:** same class of issue as the ArgoCD-install-itself incident above — `kube-prometheus-stack`'s largest CRDs (`prometheuses`, `alertmanagers`, `alertmanagerconfigs`, `prometheusagents`, `thanosrulers`, `scrapeconfigs`) have OpenAPI schemas large enough that a plain `kubectl apply`'s `last-applied-configuration` annotation exceeds the 262144-byte Kubernetes limit. Smaller CRDs (`servicemonitors`, `podmonitors`, `probes`, `prometheusrules`) synced fine; only the large ones failed, which made the symptom look partial/confusing at first.
**First attempt that didn't fully work:** adding `ServerSideApply=true` to the Application's `syncPolicy.syncOptions`. ArgoCD does not honor this Application-level setting for CRDs that come from a Helm chart's own `crds/` directory — every periodic auto-sync kept re-attempting a plain patch on those 6 CRDs and failing (retried 5 times, then gave up until the next poll), even though the CRDs already existed and everything using them worked fine.
**Actual fix:** install the CRDs once out-of-band with real server-side apply (`kubectl apply --server-side --force-conflicts -f <chart>/charts/crds/crds/`), then set `crds.enabled: false` in the Application's Helm values so the chart stops trying to manage them at all going forward (see `apps/monitoring/application.yaml`). A chart version bump that changes CRD schemas will need the same manual `--server-side` apply repeated by hand.

### `monitoring` Application's root-driven bootstrap: `AppProject`/`Application` changes never applied, sync stuck retrying forever
**Cause:** the root Application's directory-recurse sync validates every manifest under `apps/` as a single all-or-nothing batch before applying any of it. The `ServiceMonitor` manifest (`apps/monitoring/dcgm-servicemonitor.yaml`) references a CRD that only the `monitoring` Application itself installs — but that Application's own creation was *also* stuck in the same failing root batch, so nothing could ever converge on its own (a genuine bootstrap cycle, not a transient race).
**Fix:** manually `kubectl apply -f apps/appproject.yaml` and `apps/monitoring/application.yaml` once, out-of-band, the same way `bootstrap/root-app.yaml` itself is documented as "applied manually, once" (see [architecture.md](./architecture.md)). Once the `monitoring` Application exists and its CRDs are installed, the root Application's own sync (retried automatically via `selfHeal`) succeeds on its own from then on.

### `/api/embed` returns `"This server does not support embeddings. Start it with --embeddings"`
**Cause:** the `otwld/ollama-helm` chart does not pass the `--embeddings` flag by default; not something CI or `kubeconform` can catch since the manifest is schema-valid.
**Fix:** not yet applied. To enable, add `--embeddings` to the container args via the Helm values (e.g. an `extraArgs` field, chart-version-dependent) and let ArgoCD redeploy.

---

## Symptom → Probable Cause

| Symptom | Probable Cause |
|---|---|
| ArgoCD `Application` stuck `OutOfSync` after referencing a new `AppProject` | Sync-ordering race — the `AppProject` manifest hasn't landed yet. Should self-heal within one reconcile loop; add/check `argocd.argoproj.io/sync-wave: "-1"` on the project if it doesn't (see [ADR-0007](./adr/0007-dedicated-appproject.md)) |
| MetalLB stops handing out the expected IP after re-running `microk8s enable metallb:<range>` on the host | The address pool is Git-managed ([ADR-0008](./adr/0008-metallb-config-in-git.md)) — ArgoCD's `selfHeal: true` reverts host-level imperative changes back to what's in `apps/metallb-config/`. Edit the Git manifest instead. |
| GitHub push doesn't seem to deploy for several minutes | Expected — no webhook is possible on a LAN-only cluster ([ADR-0002](./adr/0002-lan-only-exposure.md)); ArgoCD polls every ~3 min. Force a refresh (see Common Tasks) for immediate feedback. |
| CI (`validate.yml`) is green but the app fails to sync/run anyway | Expected class of gap — CI only validates schema/syntax, not runtime semantics like Helm value correctness or registry tag existence ([ADR-0009](./adr/0009-static-ci-validation.md)) |
| 40Gi PVC filling up | Stale model tags not auto-pruned (`models.clean: false`) — see Common Tasks above to remove them manually |
| `monitoring` Application shows `Healthy` but `OutOfSync` even right after a clean sync | Cosmetic: the Grafana subchart's auto-generated admin-password `Secret` (and the Deployment referencing it) re-renders slightly differently on each `helm template` diff pass. Pods aren't restarting/flapping from it (check `kubectl -n monitoring get pods` restart counts) — it's a known kube-prometheus-stack/ArgoCD quirk, not a real drift |
| A `monitoring` namespace pod is `Pending` or gets `OOMKilled`, especially while a larger Ollama model is loaded | Node only has 15Gi RAM total, shared between Ollama and the monitoring stack's fixed resource requests/limits ([ADR-0012](./adr/0012-monitoring-stack.md)) — check `free -h` on the host and `sudo microk8s kubectl top pods -A` before assuming a config bug |
