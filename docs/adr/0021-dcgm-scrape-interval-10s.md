# ADR-0021: Lower DCGM scrape interval from 30s to 10s

**Date:** 2026-07-30
**Status:** Accepted

---

## Context

While investigating a specific `ollama-chat` call's GPU behavior on 2026-07-30, it became
clear that a single inference call commonly finishes in under 30 seconds — the interval
`nvidia-dcgm-exporter`'s `ServiceMonitor` was scraped at since [ADR-0012](./0012-monitoring-stack.md).
At that interval, a short call's GPU utilization spike could be missed entirely or captured as
a single unlucky (or lucky) sample, making Grafana's GPU util graph unreliable for judging any
one specific call — only useful for spotting sustained, multi-call trends.

## Decision

Lower `spec.endpoints[0].interval` in `apps/monitoring/dcgm-servicemonitor.yaml` from `30s` to
`10s`.

---

## Considered Alternatives

### Leave it at 30s

Rejected: this is the status quo that prompted the investigation — it directly causes the
blind spot described above for any call under ~30s, which is the common case on this box.

### Lower further (e.g. 5s or 1s)

Rejected for now: still wouldn't reliably catch calls finishing in a few seconds, while
increasing Prometheus's sample/storage rate for this target further (roughly 6x vs. the
original 30s at 5s, 30x at 1s). 10s is a reasonable middle ground — meaningfully better
coverage for typical multi-second-to-tens-of-seconds calls without a disproportionate scrape
load increase for a single-node homelab cluster.

### Build per-call GPU attribution instead of tuning the scrape interval

Considered, not pursued here: DCGM's metrics are GPU-wide, not per-pod/per-request, so even a
very fast scrape interval can't attribute a utilization spike to a specific call when `ollama`
and `whisper` share the GPU via time-slicing ([ADR-0017](./0017-whisper-gpu-with-keep-alive.md)).
Solving that would require a different approach entirely (e.g. correlating DCGM timestamps
against `homelab-gateway`'s per-call `durationMs`/timestamp from its Mongo `call_log` — see
that repo's `inspect-call-perf` skill) and is a bigger change than this ADR's scope.

---

## Consequences

**Good:**
- ~3x more GPU samples during and around a typical inference call, meaningfully reducing (but
  not eliminating) the chance of missing its utilization spike in Grafana.
- No new components, no schema change — a one-line config tune to an existing `ServiceMonitor`.

**Neutral:**
- Roughly 3x more `DCGM_FI_DEV_*` series samples retained over Prometheus's 15-day window
  ([ADR-0012](./0012-monitoring-stack.md)) — negligible at this cluster's single-GPU,
  single-node scale.

**Negative:**
- ⚠️ Still won't reliably catch calls finishing in a few seconds — this is a partial
  mitigation, not a fix. A call still needs to line up with a scrape tick to be visible at all.
- ⚠️ GPU metrics remain GPU-wide, not attributable to a specific pod/call when `ollama` and
  `whisper` are both scheduled via time-slicing — this change doesn't address that limitation,
  only the sampling-frequency one. See `gpu-metrics-visibility` skill for the full picture.
