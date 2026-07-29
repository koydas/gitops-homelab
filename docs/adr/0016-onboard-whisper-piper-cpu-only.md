# ADR-0016: Onboard Whisper (STT) and Piper (TTS), CPU-only, split raw-manifest vs git-source

**Date:** 2026-07-28
**Status:** Partially superseded by [ADR-0017](./0017-whisper-gpu-with-keep-alive.md) —
Whisper's CPU-only decision below no longer holds; Piper is unaffected and stays CPU-only.

---

## Context

`ollama-chat`'s vocal mode (see that repo's ADR-0011) needs a speech-to-text and a
text-to-speech backend. Ollama itself cannot serve either — it only runs GGUF-format LLM/VLM
models, not Whisper's or Piper's model formats/runtimes. Two new services are needed in this
cluster, called by `ollama-chat`'s Express backend the same way it already calls Ollama.

The node has exactly one GPU (a GTX 1060 6GB), already fully claimed by the `ollama`
Deployment. ADR-0013 confirms VRAM headroom is already down to ~1.2-1.7GB after loading the
in-use text/vision models, and that more GPU-bound work needs new hardware, not a scheduling
trick — there is no GPU-sharing/time-slicing config anywhere in this cluster
(`microk8s enable gpu --driver host` advertises exactly `nvidia.com/gpu: 1`, a single
exclusively-allocatable unit). A second pod requesting `nvidia.com/gpu` would sit `Pending`
forever alongside `ollama`.

## Decision

> **Update (2026-07-29):** confirmed usage is solo/sequential, never parallel — the
> scheduling conflict assumed below doesn't occur in practice. Whisper has since moved to
> GPU; see [ADR-0017](./0017-whisper-gpu-with-keep-alive.md). Piper's CPU-only decision is
> unaffected — no GPU-accelerated code path exists for it upstream.

Both services are deployed **CPU-only** — no `runtimeClassName: nvidia`, no
`nvidia.com/gpu` resource request on either Deployment.

- **Whisper** (`apps/whisper/`): the public, actively maintained
  `onerahmet/openai-whisper-asr-webservice:v1.9.1` image (confirmed present via
  `docker manifest inspect`, multi-arch, not the `-gpu` variant), `ASR_ENGINE=faster_whisper`,
  `ASR_MODEL=small`, `ASR_DEVICE=cpu`.
  **⚠ Superseded by [ADR-0017](./0017-whisper-gpu-with-keep-alive.md):** now the `-gpu` image
  variant, `ASR_DEVICE=cuda`, `runtimeClassName: nvidia`, `nvidia.com/gpu: 1`. The raw-manifest
  deployment pattern described below is still current — only the CPU-vs-GPU config changed.
  Deployed as **plain raw manifests** committed directly
  in this repo (`namespace.yaml`, `deployment.yaml`, `service.yaml`, no `application.yaml`) —
  same pattern as `apps/metallb-config/`, picked up automatically by `root`'s recursive
  directory sync. There is no code here to own: it's an off-the-shelf image.
- **Piper** (`apps/piper/application.yaml`): no equivalent ready-made image exposes a simple
  REST API, so a small custom FastAPI wrapper was built (`koydas/piper-tts-server`,
  `POST /tts`, French voice `fr_FR-siwis-medium` baked in at build time). Onboarded as a
  **git-source Application**, identical pattern to `ollama-chat` (ADR-0015): source repo
  owns the `Dockerfile`/CI/`k8s/`, this repo just points at it.

Both get a dedicated **LoadBalancer** Service with a MetalLB IP (`.245` Whisper, `.246`
Piper, next free slots after `.244` ollama-chat) rather than `ClusterIP`-only. Reason: Vite's
local dev proxy (in `ollama-chat`) reaches Ollama directly via its LAN LoadBalancer IP
without needing the Express backend running at all — giving Whisper/Piper the same dev-time
reachability keeps that workflow intact for the new endpoints too.

`apps/appproject.yaml` gets `https://github.com/koydas/piper-tts-server.git` added to
`sourceRepos`, and `whisper`/`piper` added to `destinations` (ADR-0007's guard rail). No
`clusterResourceWhitelist` change needed: `Namespace` is already whitelisted (covers
Whisper's raw `namespace.yaml`), and `namespaceResourceWhitelist` is already `*`/`*`.

## Considered Alternatives

### GPU-accelerated Whisper/Piper
Rejected: the single GTX 1060 is already fully committed to `ollama` per ADR-0013's own
conclusion — a second GPU-requesting pod has no path to actually schedule without new
hardware or an untested sharing scheme this cluster has no precedent for. Piper is CPU-native
by upstream design anyway (targets Raspberry Pi-class hardware); Whisper's `faster_whisper`
engine at `small` model size is workable on this node's 8 vCPU.

**⚠ Reversed for Whisper by [ADR-0017](./0017-whisper-gpu-with-keep-alive.md):** the "no path
to schedule" premise assumed Ollama and Whisper could run concurrently. Confirmed actual usage
is solo/sequential, so that conflict doesn't occur — Whisper now runs GPU-accelerated. This
rejection still stands for Piper (unchanged, still CPU-only).

### A Helm chart for either service
Rejected for both: no well-known, actively-maintained Helm chart exists for either
`openai-whisper-asr-webservice` or a plain-REST Piper wrapper — both ship as bare container
images upstream. Vendoring chart boilerplate for a single-image service would add complexity
without benefit, consistent with ADR-0015's reasoning for `ollama-chat` itself.

### Raw manifests in this repo for Piper too (skip the new repo)
Rejected: Piper is custom code we own (a FastAPI app, not just config for an upstream image)
— it needs its own build pipeline (`Dockerfile`, CI publishing to GHCR) the way `ollama-chat`
does, which belongs next to the code per ADR-0015's own reasoning. Whisper has no such code,
so raw manifests are the simpler, more direct fit there.

## Consequences

**Good:**
- Zero risk of GPU scheduling deadlock — both services fit the cluster's actual, confirmed
  hardware constraint instead of assuming headroom that doesn't exist.
- Two onboarding patterns (raw manifests, git-source Application) now both have a precedent
  for "off-the-shelf image with nothing to own" vs. "custom code with a build pipeline,"
  reusable for future services.

**Neutral:**
- A third external repo (`piper-tts-server`) now matters for "is voice mode deployed
  correctly," alongside `ollama-chat` and this repo — same shape as ADR-0015 already
  established, just one more.

**Negative:**
- ~~CPU-only Whisper at `small` model size trades some transcription latency/accuracy for
  fitting the existing hardware~~ — **no longer applies to Whisper**, which moved to GPU per
  [ADR-0017](./0017-whisper-gpu-with-keep-alive.md). Still applies to Piper (CPU-only,
  unaffected) if its model/voice size ever needs revisiting.
- Two more LoadBalancer IPs (`.245`, `.246`) consumed from the MetalLB pool for services that
  are, in production, only ever called from inside the cluster (by `ollama-chat`) — the
  LAN-reachable IP exists purely for local dev parity with Ollama's setup, not because
  anything external needs to reach them directly.
