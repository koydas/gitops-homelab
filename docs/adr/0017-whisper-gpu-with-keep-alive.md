# ADR-0017: Whisper Moves to GPU, Ollama Gets `OLLAMA_KEEP_ALIVE=30s`

**Date:** 2026-07-29
**Status:** Accepted

---

## Context

ADR-0016 deployed Whisper CPU-only because the node's single GTX 1060 6GB was assumed to
already be fully claimed by `ollama`, with no path for a second GPU-requesting pod to
schedule alongside it (`nvidia.com/gpu: 1` is a single exclusively-allocatable unit, no
sharing/time-slicing configured). ADR-0013 separately confirmed that loaded models already
leave only ~1.2-1.7GB of VRAM headroom, and that Ollama itself serves requests strictly
sequentially (no `OLLAMA_NUM_PARALLEL`).

That earlier reasoning assumed Ollama and Whisper might be invoked in parallel. Actual usage
has since been confirmed: `ollama-chat`'s vocal mode calls them **solo, sequential, never in
parallel** — Whisper transcribes a voice message, then Ollama generates a reply, one at a
time. The "both fully claim the GPU simultaneously" scenario ADR-0016 guarded against does
not occur in practice, so Whisper no longer needs to stay CPU-only to avoid a scheduling
conflict.

## Decision

Whisper moves to GPU: `apps/whisper/deployment.yaml` adds `runtimeClassName: nvidia`, sets
`ASR_DEVICE=cuda`, and requests `nvidia.com/gpu: 1` in `resources.limits` (image bumped to
the `onerahmet/openai-whisper-asr-webservice:v1.9.1-gpu` variant, confirmed present via
`docker manifest inspect`). The obsolete comment referencing ADR-0016's CPU-only rationale is
removed from above `image:`.

To keep the two workloads from actually holding the GPU's VRAM at the same time, `ollama`
(`apps/ollama/application.yaml`) gets `OLLAMA_KEEP_ALIVE=30s` via `ollama.extraEnv`, replacing
the chart's 5-minute default. Ollama now unloads its model from VRAM shortly after each
isolated request completes, freeing headroom for Whisper's GPU-resident run instead of the
two competing for the same ~1.2-1.7GB margin.

## Considered Alternatives

### GPU time-slicing (`nvidia-device-plugin`)
Rejected: adds a whole scheduling layer (device plugin config, shared-GPU replica counts) to
solve a conflict that never actually happens — usage is confirmed never concurrent, so
there's nothing to time-slice between.

### `OLLAMA_KEEP_ALIVE=0`
Considered instead of `30s`. Rejected in favor of `30s`: `0` unloads the model immediately
after every single request, forcing a full reload from disk on every isolated Ollama call
even outside vocal-mode sessions. `30s` is a compromise — long enough that a quick follow-up
Ollama request doesn't pay the reload cost, short enough that VRAM is free again well before
the next Whisper call in a typical vocal-mode turn.

## Consequences

**Good:**
- Whisper transcription is faster on GPU (`small` model) than on CPU (2 cores), matching
  actual confirmed sequential usage instead of the more conservative CPU-only assumption.
- No new scheduling complexity: both Deployments simply request `nvidia.com/gpu: 1` each,
  relying on non-overlapping usage rather than a sharing mechanism.

**Neutral:**
- Replaces ADR-0016's CPU-only decision for Whisper specifically; Piper stays CPU-only (no
  GPU-accelerated code path exists for it upstream).

**Negative:**
- The first Ollama request after more than 30s idle pays a model-reload-from-disk latency
  penalty it didn't before (previously kept warm for 5 minutes).
- If usage ever becomes genuinely parallel (Whisper and Ollama invoked concurrently), both
  Deployments requesting `nvidia.com/gpu: 1` will contend for the single allocatable unit and
  one will sit `Pending` — revisit by reverting Whisper to CPU-only or introducing GPU
  time-slicing at that point, per the alternatives above.
