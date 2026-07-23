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
