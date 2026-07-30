---
name: gpu-metrics-visibility
description: What GPU/inference performance data is actually visible in this cluster's monitoring stack, and where it isn't. Covers DCGM scrape granularity vs. short calls, and the fact Ollama exposes no native /metrics. Use when asked about GPU metrics, inference performance, or improving observability for Ollama/whisper/piper workloads.
---

# GPU / inference metrics visibility limits

## When to Apply

Someone asks to check, debug, or improve GPU/inference performance visibility in Grafana/
Prometheus for Ollama, Whisper, or Piper — not for cluster-level GPU state (see the
`homelab-status` skill for that).

## What's actually scraped today

`nvidia-dcgm-exporter` (`apps/monitoring/dcgm-servicemonitor.yaml`), scraped every 10s (lowered
from 30s on 2026-07-30, see below): device-level `utilization.gpu`, `memory.used`,
`power.draw`, `temperature.gpu`. This is GPU-wide, not per-pod or per-request — it can't tell
you which workload caused a spike if `ollama` and `whisper` are both scheduled (see ADR-0017 on
GPU time-slicing).

**Ollama itself exposes no `/metrics` endpoint** (confirmed 404 on port 11434 internally) — no
native per-request timing stats ever reach Prometheus directly *from Ollama itself*. Two other
paths exist:

- Ollama pod stdout logs (`llama-server`'s verbose per-request breakdown: GPU layers offloaded,
  per-image-batch decode timing) — ephemeral, no log aggregator (no Loki) in this cluster, lost
  on pod rotation, not queryable. This is still the only place that level of detail exists.
- For calls routed through `homelab-gateway`: since 2026-07-30
  (`homelab-gateway`'s ADR-0002), Ollama's own generation-speed stats (prompt eval tok/s, eval
  tok/s, token counts) are extracted server-side into structured Mongo `call_log` fields *and*
  a `gateway_ollama_tokens_per_second{model}` Prometheus histogram — no longer buried as raw
  text. See that repo's `inspect-call-perf` skill for querying either.

## The scrape interval blind spot

A single inference call commonly finishes in under 30s, which is why the interval was lowered
from `30s` to `10s` in `apps/monitoring/dcgm-servicemonitor.yaml`
(`spec.endpoints[0].interval`) on 2026-07-30 ([ADR-0021](../../docs/adr/0021-dcgm-scrape-interval-10s.md))
— the old interval could miss a short call's GPU utilization spike entirely. Tradeoff: ~3x more
Prometheus samples/storage for this target, negligible at this cluster's scale. Even at 10s, a
call finishing in a few seconds can still be missed or under-sampled — Grafana's GPU util graph
remains better for spotting sustained/multi-call trends than for judging one specific short
call. Going much below 10s stops being worth the added scrape load for this size of cluster.
This is still a GPU-wide sampling fix, not per-pod attribution — see the note above on
time-slicing.

## What's not worth building here

Standing up a log aggregator (Loki or similar) just to persist `llama-server`'s verbose
per-request log lines (GPU layers offloaded, per-image-batch decode timing) is disproportionate
to how often that detail is actually needed — it's occasional debugging information, not a
metric anyone tracks over time. Per-call token/sec *is* now tracked over time (see above,
`homelab-gateway` ADR-0002) without needing a new stateful component in this cluster; only the
GPU-layer/batch-timing detail remains ephemeral by choice, not by oversight.

## References

- `apps/monitoring/dcgm-servicemonitor.yaml` — the exporter's scrape config
- `docs/adr/0012-monitoring-stack.md` — why Prometheus/Grafana were added and what they cover
- `docs/adr/0017-*` (GPU time-slicing) — why GPU-wide metrics can't be attributed to one pod
- `docs/adr/0021-dcgm-scrape-interval-10s.md` — the scrape-interval change and its limits
- `homelab-gateway`'s `inspect-call-perf` skill and ADR-0002 — the gateway-side stats extraction
