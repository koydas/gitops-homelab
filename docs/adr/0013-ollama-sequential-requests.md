# ADR-0013: Ollama Serves Requests Sequentially (No `OLLAMA_NUM_PARALLEL`)

**Date:** 2026-07-24
**Status:** Accepted

---

## Context

With Prometheus/Grafana now scraping GPU metrics ([ADR-0012](./0012-monitoring-stack.md)), the user ran a manual load test against Ollama: 1 request, then 2 requests fired together, then 5 requests fired together, all against `qwen2.5-coder:7b-instruct-q4_0`. GPU utilization and Ollama's own request logs were checked live to see how the deployment actually behaves under concurrency, not just how it's configured.

`apps/ollama/application.yaml` does not set `OLLAMA_NUM_PARALLEL` (or any concurrency-related env var) — Ollama runs with its default, which is 1 concurrent generation slot per model on this deployment.

---

## Decision

Keep the default: no `OLLAMA_NUM_PARALLEL` override. Concurrent requests queue and are served strictly one at a time.

---

## Considered Alternatives

### Verify actual behavior before deciding (not assumed)

Checked `sudo microk8s kubectl -n ollama logs deploy/ollama` timestamps for the test's `POST /api/generate` completions, and cross-referenced `DCGM_FI_DEV_FB_USED`/`DCGM_FI_DEV_GPU_UTIL` in Prometheus for the same window:

| Requests fired together | Individual completion times | Inferred start time (completion − duration) |
|---|---|---|
| 1 | 30.3s | immediate |
| 2 (14s apart) | 30.3s, 55.7s | both start within the first request's runtime |
| 5 (within ~10s of each other) | 32.0s, 1m01s, 1m31s, 1m56s, 2m26s | all 5 started within a ~10s window |

The 5-concurrent completion times step up by almost exactly ~30s each (one request's solo runtime) — the signature of pure serial queuing, not parallel execution. Ollama's own logs confirm this directly: only `slot id 0` is ever used, and `srv update_slots: all slots are idle` appears between each task before the next one starts. `DCGM_FI_DEV_FB_USED` stayed flat at 4382 MiB throughout all three tests (one model resident, never duplicated), and `DCGM_FI_DEV_GPU_UTIL` showed one continuous 90%+ busy stretch spanning the 2- and 5-request bursts, not overlapping/interleaved spikes.

Practical throughput implication, confirmed rather than theoretical: **N simultaneous requests ≈ N × ~30s until the last one completes**, regardless of how many are fired at once.

### `OLLAMA_NUM_PARALLEL > 1`

Not enabled. The GTX 1060 has 6GB VRAM and the currently-loaded 7-8B Q4_0 models already leave only ~1.2-1.7GB headroom ([ADR-0011](./0011-ollama-q4-quantization.md)). True parallelism multiplies per-request KV-cache memory, not just compute — on a card this tight on VRAM, forcing concurrent slots would risk OOM or force smaller context windows, and would still contend for the same compute (Pascal, no tensor cores), so total throughput for N requests would not meaningfully improve and latency-per-request would likely get worse across the board rather than one request finishing fast while others queue cleanly.

---

## Consequences

**Good:**
- Simple, predictable behavior: exactly one generation at a time, no risk of concurrent requests contending for VRAM and OOM-crashing the pod.
- Matches the hardware's actual constraint (single Pascal GPU, tight VRAM) rather than configuring for a parallelism the card can't cleanly support.

**Neutral:**
- Multiple simultaneous users/requests will queue, not run in parallel — a request behind 4 others waits for all of them (confirmed: 2m26s for the 5th of 5 simultaneous requests that alone takes 30s). Acceptable for this homelab's usage pattern (single operator, not a multi-user service); revisit if usage patterns change.

**Negative:**
- No horizontal headroom for concurrent load on this GPU without accepting either OOM risk or a real (unverified) throughput/latency trade-off from enabling `OLLAMA_NUM_PARALLEL`. If concurrent-user support is ever needed, the real fix is a second/larger GPU, not just a config flag on this one.
