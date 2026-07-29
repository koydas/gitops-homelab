# ADR-0017: Whisper Moves to GPU via Time-Slicing, with Ollama Keep-Alive

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

Actual usage has since been confirmed: `ollama-chat`'s vocal mode calls Ollama and Whisper
**solo, sequential, never in parallel** — Whisper transcribes a voice message, then Ollama
generates a reply, one at a time.

That confirmed usage pattern is **not**, on its own, enough to let Whisper share the GPU with
Ollama. Both are long-running `Deployment`s (`replicas: 1`), and Kubernetes' extended-resource
scheduling reserves a requested `nvidia.com/gpu` unit for a pod's **entire lifetime** once it's
scheduled — not just while that pod is actively computing on the device. A node advertising a
single allocatable `nvidia.com/gpu: 1` can therefore only ever run one of the two Deployments;
whichever schedules first keeps the only unit indefinitely, and the other sits `Pending`
forever, regardless of how idle the first one actually is at any given moment.
`OLLAMA_KEEP_ALIVE` unloading Ollama's model from VRAM does nothing to release that
Kubernetes-level allocation. This gap was caught in code review before merge — the original
version of this ADR assumed confirmed sequential *application* usage was sufficient by itself,
which it is not, at the *scheduling* layer.

## Decision

Whisper moves to GPU (`runtimeClassName: nvidia`, `ASR_DEVICE=cuda`, `nvidia.com/gpu: 1`,
`onerahmet/openai-whisper-asr-webservice:v1.9.1-gpu` — confirmed present via
`docker manifest inspect`), same as originally planned. The obsolete comment referencing
ADR-0016's CPU-only rationale is removed from above `image:` in
`apps/whisper/deployment.yaml`.

To actually let both `ollama` and `whisper` schedule at the same time, GPU **time-slicing** is
enabled via the NVIDIA device plugin: `apps/gpu-time-slicing/configmap.yaml` defines a
`time-slicing-config` ConfigMap with `replicas: 2` for `nvidia.com/gpu`, splitting the single
physical GPU into 2 allocatable units — one for each Deployment. The cluster's `ClusterPolicy`
(a singleton created imperatively by the microk8s `nvidia` addon, not owned by this repo) has
to be patched by hand, once, to reference that ConfigMap — see the README's "Recreate from
scratch" section.

`ollama` (`apps/ollama/application.yaml`) still gets `OLLAMA_KEEP_ALIVE=30s` via
`ollama.extraEnv`, replacing the chart's 5-minute default. With time-slicing solving the
*scheduling* conflict, this now does the job it was originally meant for: once both pods can
be `Running` simultaneously, keeping Ollama's model resident in VRAM for the full default
5 minutes between isolated requests would eat into the already-tight ~1.2-1.7GB headroom
(ADR-0013) that Whisper's own GPU working set also needs. 30s bounds how long Ollama holds
VRAM after a request before freeing it back up.

## Considered Alternatives

### Rely on confirmed sequential app-level usage alone (no time-slicing)
This was the original decision behind this ADR, before review caught the flaw above.
Rejected: it addresses only whether Ollama and Whisper are *called* concurrently, not whether
Kubernetes will *schedule* both pods concurrently. Two always-on Deployments each requesting
`nvidia.com/gpu: 1` against a node advertising exactly one allocatable unit cannot both reach
`Running` — one is permanently `Pending` — irrespective of how idle either actually is at
runtime.

### `OLLAMA_KEEP_ALIVE=0`
Rejected: unloads Ollama's model after every single request, forcing a full reload from disk
on every isolated Ollama call, not just ones during a vocal-mode turn. `30s` is a compromise —
long enough that a quick follow-up Ollama request doesn't pay the reload cost, short enough to
free VRAM before Whisper's next call in a typical vocal-mode turn.

### Scale one Deployment to 0 replicas around each request
Rejected: would need `ollama-chat`'s Express backend (or some other controller) to scale
`whisper` up before each transcription and back down after, and likewise for `ollama` — adds
pod cold-start plus model-reload-from-disk latency to *every* turn, and couples this repo's
GPU scheduling to orchestration logic living outside GitOps' declarative model, for a problem
time-slicing solves with a one-time cluster config.

### Revert Whisper to CPU-only (keep ADR-0016 as-is)
Rejected: gives up the GPU speed benefit this ADR set out to get, when time-slicing directly
fixes the actual blocker (Kubernetes-level allocation) rather than working around it. Kept in
mind as the fallback if time-slicing proves unstable in practice (see Consequences).

## Consequences

**Good:**
- Both `ollama` and `whisper` can actually be `Running` at the same time — the real blocker
  (single allocatable `nvidia.com/gpu` unit reserved per pod lifetime) is fixed at its source
  instead of assumed away by application-level usage patterns.
- Whisper gets its GPU speed benefit (`small` model, GPU vs. CPU 2 cores) as intended.

**Neutral:**
- Time-slicing shares GPU *compute* scheduling only — it does not partition or reserve VRAM
  per slice. Both pods still draw from the same 6GB physical VRAM pool; nothing here
  guarantees they can't OOM each other if truly invoked at the same instant. This ADR still
  relies on confirmed solo/sequential *application* usage to avoid that in practice —
  time-slicing only removes the Kubernetes-level scheduling deadlock, it is not a VRAM
  isolation mechanism.
- The `ClusterPolicy` patch is a manual, host-level, one-time step (same pattern as the
  `monitoring` app's Grafana secret and CRD bootstrap) — not GitOps-managed, since
  `ClusterPolicy` is a singleton created imperatively by the microk8s `nvidia` addon and its
  full live spec couldn't be verified against this session (no cluster access), making a
  full in-Git resource too risky to encode blind. Must be re-applied after any cluster
  rebuild — added to the README's "Recreate from scratch" checklist.

**Negative:**
- If usage ever becomes genuinely concurrent (real simultaneous GPU compute, not just
  concurrent scheduling), 2 time-sliced contexts on a single Pascal-generation GPU contend for
  the same SMs — time-slicing avoids the `Pending` deadlock but provides no compute-level
  speedup for true parallelism, and remains exposed to the VRAM contention noted above.
- The first Ollama request after more than 30s idle pays a model-reload-from-disk latency
  penalty it didn't before (previously kept warm for 5 minutes).
