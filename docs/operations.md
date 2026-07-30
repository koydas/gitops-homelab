# Monitoring and ingress

## Monitoring flow (GPU metrics)

1. `nvidia-dcgm-exporter` (deployed by the microk8s `gpu` addon, namespace `gpu-operator-resources`) exposes GPU telemetry (temperature, power, utilization, framebuffer memory) on port 9400.
2. A `ServiceMonitor` (`apps/monitoring/dcgm-servicemonitor.yaml`) tells Prometheus (deployed by the `monitoring` Application's kube-prometheus-stack chart) to scrape it every 10s, across namespaces (lowered from 30s, see [ADR-0021](./adr/0021-dcgm-scrape-interval-10s.md) — most inference calls finish faster than the old interval could reliably sample).
3. Prometheus stores samples on its PVC (`microk8s-hostpath`, 15 day retention — see [ADR-0012](./adr/0012-monitoring-stack.md)).
4. Grafana, provisioned with a Prometheus datasource by the chart and a GPU dashboard (`apps/monitoring/dcgm-dashboard-configmap.yaml`, labeled `grafana_dashboard: "1"` so the chart's sidecar auto-loads it), is reachable at its own MetalLB IP (`192.168.1.242:80`, see [runbook.md](./runbook.md) for login).

## Ingress flow (host-routed apps)

1. `ingress-nginx` (`apps/ingress-nginx/application.yaml`) is the one `IngressClass` for the cluster (`ingressClassResource.default: true`), reachable at a pinned MetalLB IP (`192.168.1.243`, see [ADR-0014](./adr/0014-ingress-nginx-controller.md)).
2. A future HTTP app adds its own `Ingress` object naming a hostname; no client-facing MetalLB IP of its own is needed. `ollama-chat` (ADR-0015) is the first: its `Ingress` lives in its own repo's `k8s/` dir, not under `apps/` here, since it's a git-source Application rather than a Helm chart — see ADR-0015.
3. The operator's device resolves that hostname (e.g. `ollama-chat.home`) to `.243` (`/etc/hosts` entry or LAN DNS — no DNS server exists in this environment yet), and ingress-nginx routes by `Host` header to the right Service.
4. Still LAN-only: no public domain, no cert-manager/TLS — see [ADR-0002](./adr/0002-lan-only-exposure.md), amended by ADR-0014 only for the internal routing model, not the exposure boundary.
