# ADR-0012: kube-prometheus-stack (full) for GPU Monitoring, LoadBalancer-Exposed, 15-Day Retention

**Date:** 2026-07-24
**Status:** Accepted

---

## Context

The repo/server review on 2026-07-24 (`.ai-reports/2026-07-24-1450-analyse-repo-serveur.md`) found that `nvidia-dcgm-exporter` is already deployed (by the microk8s `gpu` addon, in `gpu-operator-resources`, service `nvidia-dcgm-exporter:9400`) but nothing scrapes it — there is no history of GPU temperature, power draw, utilization, or VRAM usage, only the live snapshot `nvidia-smi` gives.

This is a single-node homelab: 8 vCPU / 15Gi RAM allocatable, one GTX 1060 6GB already dedicated to Ollama inference (see [ADR-0003](./0003-ollama-in-cluster.md)), ~65% of the 98G disk free. Whatever gets deployed has to leave enough headroom for Ollama and not become its own operational burden.

---

## Decision

Deploy Prometheus + Grafana via the `prometheus-community/kube-prometheus-stack` Helm chart (pinned `87.19.1`, latest at time of writing — confirmed against the chart's published `index.yaml`), as a new ArgoCD Application (`apps/monitoring/application.yaml`), same GitOps pattern as `apps/ollama/application.yaml`. Scrape `nvidia-dcgm-exporter` via an explicit `ServiceMonitor` (`apps/monitoring/dcgm-servicemonitor.yaml`), and provision the official NVIDIA DCGM Grafana dashboard (ID 12239) via a labeled ConfigMap (`apps/monitoring/dcgm-dashboard-configmap.yaml`) so it's live without a manual import step.

---

## Considered Alternatives

### Minimal stack (standalone `prometheus` + `grafana` charts, no Alertmanager/node-exporter/kube-state-metrics)

Lighter, but loses the `ServiceMonitor` CRD (Prometheus Operator installs it) — scraping `dcgm-exporter` would mean a static `scrape_configs` entry baked into Helm values instead of a Git-native custom resource, and there'd be no reusable pattern (CRD + operator) for monitoring anything added to the cluster later. Rejected: the operator/CRD pattern is the standard way to extend Prometheus in Kubernetes, and this repo already leans on CRDs elsewhere (MetalLB's `IPAddressPool`, see [ADR-0008](./0008-metallb-config-in-git.md)).

### Exposure: `ClusterIP` + `kubectl port-forward` instead of `LoadBalancer`

Would avoid consuming another MetalLB IP, but breaks the pattern already established for ArgoCD (`192.168.1.240`) and Ollama (`192.168.1.241`) — both get a permanent LAN IP, no ad hoc port-forwarding. The pool (`192.168.1.240-250`, [ADR-0008](./0008-metallb-config-in-git.md)) has room; Grafana takes `192.168.1.242`. Rejected in favor of consistency with the existing two Applications.

### Ephemeral Prometheus storage (no PVC)

Zero disk footprint, but defeats the actual point of this ADR — an unplanned pod restart (node reboot, chart upgrade, OOM) would silently erase the GPU history this deployment exists to capture. Rejected; Prometheus gets a 10Gi PVC on `microk8s-hostpath` (same storage class as the Ollama PVC) with 15-day retention, negligible against the 65%-free 98G disk.

### Resource sizing

The chart's own `values.yaml` (checked directly from the downloaded chart tarball) defaults every component's `resources` to `{}` — no requests or limits at all. On an 8 vCPU / 15Gi node also running Ollama, an unbounded Prometheus (memory scales with active series count) is a real risk to the node's other workload. Explicit requests/limits were set per component in `apps/monitoring/application.yaml` (Prometheus: 512Mi/1Gi memory; Grafana: 128Mi/256Mi; Alertmanager, prometheus-operator, kube-state-metrics, node-exporter: 64-128Mi each) — sums to roughly 1.7Gi memory at worst case, leaving the rest of the node's 15Gi for Ollama.

### Grafana admin credentials

Confirmed (chart's `_helpers.tpl`) that when `adminPassword` and `admin.existingSecret` are both left unset, the chart auto-generates a random 40-character password on first install and reuses it (via a `lookup`) on subsequent syncs, rather than a fixed default. Left unset — same "generated Secret, not in Git" pattern as the ArgoCD admin password.

In practice, that `lookup`-based reuse did not reliably hold across every ArgoCD sync — the generated password value changed at least once. Without persistent storage, Grafana's SQLite user DB (which holds the actual password hash) lived on the pod's ephemeral filesystem and got rebuilt from the Secret's value at each pod boot, so a restart landing between two syncs with different secret values locked users out. `grafana.persistence` (1Gi, `microk8s-hostpath`) was added after this was hit in practice — see [runbook.md](./runbook.md) — so the admin password now survives pod restarts independent of the Secret.

---

## Consequences

**Good:**
- GPU telemetry now has 15 days of history instead of only a live `nvidia-smi` snapshot.
- Same ArgoCD app-of-apps + AppProject pattern as Ollama — no new deployment mechanism to learn.
- Grafana dashboard is provisioned from Git (ConfigMap), not a manual "Import dashboard 12239" click that wouldn't survive a fresh install.
- Corrected an upstream bug while embedding the dashboard: dashboard 12239's "GPU Framebuffer Mem Free" panel queried `DCGM_FI_DEV_FB_USED` (same metric as the "Mem Used" panel) instead of `DCGM_FI_DEV_FB_FREE` — fixed in the embedded copy.
- Also migrated dashboard 12239 (`schemaVersion: 22`, dated 2020) off the legacy Angular-based `graph`/`yaxes` panel type to `timeseries`/`fieldConfig` — Grafana 13.1.1 (this chart's bundled version) no longer renders the old panel type at all, so the dashboard failed to load until this was done. See [runbook.md](./runbook.md).

**Neutral:**
- The chart requires cluster-scoped resources (CRDs, ClusterRoles/Bindings, admission webhook configs) that the `homelab` AppProject previously blocked outright (`clusterResourceWhitelist: []`); the whitelist was extended to the specific kinds this chart needs (see `apps/appproject.yaml`), rather than opened up generally.
- `dcgm-exporter` runs in `gpu-operator-resources`, not `monitoring` — the `ServiceMonitor` uses a cross-namespace selector (`serviceMonitorNamespaceSelector: {}`) rather than the chart's default release-scoped selection.
- First sync may take an extra ~3 minute ArgoCD poll cycle: the `ServiceMonitor` and dashboard `ConfigMap` are tagged `sync-wave: "1"` so they apply only after the chart (wave "0", which installs the `ServiceMonitor` CRD) is healthy, rather than racing it.

**Negative:**
- Adds roughly 1.5-1.7Gi of memory footprint and several more pods to a single-node cluster that was previously just ArgoCD + Ollama — more surface area to keep healthy.
- Alertmanager is deployed (part of the full chart) but unconfigured — no notification receivers. It's inert rather than actively useful until/unless alerting is set up.
- Pruning of Prometheus's own PVC data is time-based (15d retention) but the PVC itself, like the Ollama PVC, isn't size-capped beyond its 10Gi request — worth revisiting if disk pressure ever becomes a concern.
- The chart's own 6 largest CRDs (`prometheuses`, `alertmanagers`, `alertmanagerconfigs`, `prometheusagents`, `thanosrulers`, `scrapeconfigs`) are **not** Git/ArgoCD-managed (`crds.enabled: false` — see [runbook.md](./runbook.md) for why). They were installed once by hand with `kubectl apply --server-side --force-conflicts`. A future chart version bump that changes these CRDs' schemas needs that same manual step repeated — it will not happen automatically via `git push`.
