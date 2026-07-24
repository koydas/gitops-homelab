# Testing

There is no automated test suite against the live cluster (see [ADR-0009](./adr/0009-static-ci-validation.md) for why CI stops at static manifest validation). Verification is manual, using the tools below.

## Postman collection

[`postman/ollama.postman_collection.json`](../postman/ollama.postman_collection.json) — import into Postman. Variables: `base_url` (Ollama Service MetalLB IP), `model` / `small_model` / `code_model` (the three currently-pulled tags).

Covers: health check, version, `/api/tags`, `/api/ps`, `/api/show`, `/api/generate` (streaming + non-streaming), `/api/chat` (single + multi-turn), `/api/embed` (documented as an expected-failure check — see [runbook.md](./runbook.md)), and a code-generation prompt against the coder model.

## Quick curl checks

```bash
# Models currently pulled
curl -s http://192.168.1.241:11434/api/tags | jq

# Inference sanity check
curl -s http://192.168.1.241:11434/api/generate -d '{
  "model": "llama3.1:8b-instruct-q4_0",
  "prompt": "Say hello in one sentence.",
  "stream": false
}' | jq -r '.response'
```

## Full stack verification checklist

Used when standing this up from scratch (`bootstrap/install-host.sh` + `bootstrap/root-app.yaml`), or after a significant change:

1. `sudo microk8s status --wait-ready` — cluster healthy
2. `sudo microk8s kubectl get pods -n gpu-operator-resources` — all `Running`/`Completed`
3. GPU visible from inside a pod (`nvidia-smi` in a throwaway pod requesting `nvidia.com/gpu: 1`)
4. ArgoCD UI reachable, `root` and all child `Application`s `Synced`/`Healthy`
5. Ollama pod `Running`, PVC `Bound`
6. Functional inference request returns a real response
7. GPU utilization actually spikes during that request (`nvidia-smi` — see Common Tasks in [runbook.md](./runbook.md)) — proves it's not silently running on CPU
8. Pod restart: delete the Ollama pod, confirm the replacement reuses the PVC (fast `/api/pull` no-op in the logs, not a multi-minute re-download)
9. **The core GitOps property** ([ADR-0001](./adr/0001-kubernetes-gitops-over-docker.md)): edit `models.pull`, commit, push, force a refresh, confirm the new model is pulled and servable — with no manual cluster command beyond the Git push and the refresh annotation

All nine were run live against this deployment and passed; incidents encountered along the way are in [runbook.md](./runbook.md).

## Monitoring stack checklist (Prometheus/Grafana)

See [ADR-0012](./adr/0012-monitoring-stack.md) for context; incidents hit standing this up are in [runbook.md](./runbook.md).

1. `sudo microk8s kubectl -n monitoring get pods,pvc` — all `Running`/`Bound`, including `prometheus-monitoring-kube-prometheus-prometheus-0` and `monitoring-grafana-0` (a StatefulSet pod, not a Deployment — see ADR-0012 on why)
2. `monitoring` Application `Healthy` in ArgoCD (its `OutOfSync` status is a known cosmetic quirk, not a real problem — see runbook.md)
3. Prometheus target health — `nvidia-dcgm-exporter` should show `up`:
   ```bash
   sudo microk8s kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 &
   curl -s http://localhost:9090/api/v1/query?query=DCGM_FI_DEV_GPU_TEMP | jq
   ```
   Should return a real value (compare against `nvidia-smi` on the host).
4. Grafana reachable and the GPU dashboard actually renders (not just "the API returns 200" — this repo already hit a dashboard that loaded fine via the API but failed to render in the browser due to a legacy panel type, see runbook.md):
   ```bash
   GRAFANA_PW=$(sudo microk8s kubectl -n monitoring get secret grafana-admin-credentials -o jsonpath="{.data.admin-password}" | base64 -d)
   curl -s -u "admin:${GRAFANA_PW}" http://192.168.1.242/api/dashboards/uid/Oxed_c6Wz -o /dev/null -w "%{http_code}\n"
   ```
   Then actually open `http://192.168.1.242` in a browser and confirm the panels show data, not an error banner.
5. Password durability: delete the Grafana pod, wait for it to come back, confirm the *same* password from step 4 still works (proves the fix in ADR-0012 holds, not just that persistence exists).
6. Metrics durability: delete the Prometheus pod, wait for it to come back, confirm a query for data from before the restart still returns results (proves the PVC/retention setup actually works, not just that it's configured).
