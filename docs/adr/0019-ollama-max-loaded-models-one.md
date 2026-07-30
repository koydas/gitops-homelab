# ADR-0019: Cap Ollama to One Loaded Model at a Time

**Date:** 2026-07-30
**Status:** Accepted

---

## Context

Live incident, 2026-07-30: in `ollama-chat`, a user sent a text message ("Salut ça va ?",
routed to `llama3.1:8b-instruct-q4_0`), got a reply, then sent a photo with no text
(routed to `qwen2.5vl:3b` per `ollama-chat`'s [ADR-0009](https://github.com/koydas/ollama-chat/blob/main/docs/adr/0009-fixed-chat-mode-automatic-model-routing.md)).
The image request returned a `500` after ~11s.

`sudo microk8s kubectl logs -n ollama` for the actual crash:

```
ggml_backend_cuda_buffer_type_alloc_buffer: allocating 1825.82 MiB on device 0: cudaMalloc failed: out of memory
ggml_gallocr_reserve_n_impl: failed to allocate CUDA0 buffer of size 1914513024
...
level=ERROR msg="llama-server terminated" error="signal: aborted (core dumped)"
level=WARN msg="runtime OOM detected; expiring loaded models to clear memory before next request"
[GIN] 500 | 10.866092318s | POST "/api/chat"
```

`llama3.1:8b-instruct-q4_0` was still resident (within the `OLLAMA_KEEP_ALIVE=30s` window from
[ADR-0017](./0017-whisper-gpu-with-keep-alive.md)) when the vision model tried to load
alongside it. `nvidia-smi --query-compute-apps` at the time of investigation showed
`whisper`'s pod permanently holding ~1.3-1.4GB of VRAM even while idle (loaded model, not
actively transcribing) — confirming ADR-0017's own "Neutral" caveat that time-slicing fixes
Kubernetes-level *scheduling* but does nothing to prevent VRAM contention between whatever is
actually resident. This incident is a new variant of that risk ADR-0017 flagged: not
Ollama-vs-Whisper concurrent *invocation* (vocal mode wasn't in use), but Ollama trying to
hold **two of its own models** (text + vision) resident at once, on top of Whisper's constant
baseline footprint, on a 6GB card.

No `OLLAMA_MAX_LOADED_MODELS` was set — Ollama's default lets it decide, based on its own
memory estimate, whether a new model can be loaded alongside an already-resident one rather
than always unloading the old one first. That estimate did not account for enough headroom,
and the failure mode was not a clean "not enough memory, reject the request" — it was a hard
process abort in the middle of image-encoding.

---

## Decision

Set `OLLAMA_MAX_LOADED_MODELS=1` in `apps/ollama/application.yaml`'s `ollama.extraEnv`. This
forces Ollama to always fully unload the previous model before loading a different one,
instead of attempting to keep both resident.

---

## Considered Alternatives

### Leave the default (no cap) and rely on `OLLAMA_KEEP_ALIVE=30s` alone
This is what was in place when the incident happened — rejected as insufficient: `KEEP_ALIVE`
bounds *how long* an idle model stays loaded, but does nothing to stop Ollama from attempting
to load a second, different model *before* that timer expires, which is exactly what crashed
here.

### Reduce `OLLAMA_KEEP_ALIVE` further (e.g. `0s`)
Rejected: still doesn't guarantee the old model is unloaded *before* the new one starts
loading (same race), and would additionally force a full reload-from-disk on every single
Ollama call, even ones using the same model back-to-back — a much larger latency cost than
`OLLAMA_MAX_LOADED_MODELS=1`, which only pays that cost when the model actually changes.

### Give Ollama a dedicated, larger GPU
Rejected for the same reason ADR-0013 rejected it for concurrency: not an available option on
this homelab's single GTX 1060 node. Revisit only if the hardware changes.

---

## Consequences

**Good:**
- Eliminates this crash: Ollama can no longer attempt to hold two different models resident
  at once, regardless of the `KEEP_ALIVE` timer's state.
- No change needed in `ollama-chat` itself — the fix lives entirely in how Ollama manages its
  own VRAM.

**Neutral:**
- Whisper's own resident VRAM footprint is untouched by this change; it still permanently
  reserves ~1.3-1.4GB whenever its pod is up, same as before ADR-0017's Neutral consequence
  already noted.

**Negative:**
- Every time a conversation alternates between the text model and the vision model (or any
  two different models), the newly-requested one now always pays a full reload-from-disk
  latency penalty, instead of sometimes finding both already warm. Confirmed acceptable
  trade-off for this single-operator homelab given the alternative is a hard crash.
