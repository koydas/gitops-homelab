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

**Ollama itself exposes no `/metrics` endpoint** (confirmed 404 on port 11434 internally) —
none of its native per-request timing stats (prompt eval tok/s, eval tok/s, token counts) ever
reach Prometheus directly from Ollama. The only place those numbers exist at all:

- Ollama pod stdout logs (`llama-server`'s verbose per-request breakdown) — ephemeral, no log
  aggregator (no Loki) in this cluster, lost on pod rotation, not queryable.
- For calls routed through `homelab-gateway`: buried as raw text inside its Mongo `call_log`
  responses (Ollama's own NDJSON stream includes a final stats line) — see that repo's
  `inspect-call-perf` skill for how to read it and its own caps/limits.

## The scrape interval blind spot

A single inference call commonly finishes in under 30s, which is why the interval was lowered
from `30s` to `10s` in `apps/monitoring/dcgm-servicemonitor.yaml`
(`spec.endpoints[0].interval`) on 2026-07-30 — the old interval could miss a short call's GPU
utilization spike entirely. Tradeoff: ~3x more Prometheus samples/storage for this target,
negligible at this cluster's scale. Even at 10s, a call finishing in a few seconds can still be
missed or under-sampled — Grafana's GPU util graph remains better for spotting sustained/
multi-call trends than for judging one specific short call. Going much below 10s stops being
worth the added scrape load for this size of cluster.

## What's not worth building here

Standing up a log aggregator (Loki or similar) just to persist `llama-server`'s verbose
per-request log lines (GPU layers offloaded, per-image-batch decode timing) is disproportionate
to how often that detail is actually needed — it's occasional debugging information, not a
metric anyone tracks over time. If per-call token/sec history becomes a real ongoing need,
extracting Ollama's own stats gateway-side (already-available data, see `homelab-gateway`'s
`inspect-call-perf` skill) is a much smaller change that covers all gateway-routed traffic
without adding a new stateful component to this cluster.

## References

- `apps/monitoring/dcgm-servicemonitor.yaml` — the exporter's scrape config
- `docs/adr/0012-monitoring-stack.md` — why Prometheus/Grafana were added and what they cover
- `docs/adr/0017-*` (GPU time-slicing) — why GPU-wide metrics can't be attributed to one pod
- `homelab-gateway`'s `inspect-call-perf` skill — the gateway-side half of this same gap
