# ADR-0020: Onboard `homelab-gateway` as a git-source Application

**Date:** 2026-07-30 (written retroactively — the app itself was onboarded 2026-07-29,
commit `0f00ecd`; this ADR closes a documentation gap, `ollama-chat` and `whisper`/`piper` got
one at onboarding time, this one didn't)
**Status:** Accepted

---

## Context

`ollama-chat`, Whisper, and Piper (ADR-0015, ADR-0016) each expose their own MetalLB IP and
have no shared entry point or unified request metrics. As more backends accumulate behind
`ollama-chat`, there's no single place to see total call volume/latency/model usage across
all three, and every new client has to know which of three IPs/ports to call for which kind
of request.

## Decision

`apps/homelab-gateway/application.yaml` onboards `koydas/homelab-gateway` as a **git-source**
Application, the same pattern already established by `ollama-chat` (ADR-0015) and Piper
(ADR-0016): this repo only holds the `Application` pointer, the Deployment/Service/Ingress/
ServiceMonitor manifests live in that repo's own `k8s/` directory.

- `apps/appproject.yaml` gets `https://github.com/koydas/homelab-gateway.git` added to
  `sourceRepos` and namespace `homelab-gateway` added to `destinations` (ADR-0007's guard
  rail). No `clusterResourceWhitelist` change needed — everything it deploys is
  namespace-scoped.
- Reached via the shared `ingress-nginx` entry point (ADR-0014) at `gateway.home`, not its own
  MetalLB IP — by this point the third app to use the path ADR-0014 anticipated (after
  `ollama-chat`), and deliberately so: only 4 addresses were left in the MetalLB pool
  (`192.168.1.240-250`) by the time this was onboarded, and a dedicated IP per LAN-facing app
  was no longer sustainable.
- It fronts Ollama, Whisper, and Piper by content-based routing (audio/multipart → Whisper,
  JSON `text` → Piper, JSON `model` or bodiless → Ollama) and exports Prometheus counters/
  histograms per backend — see that repo's README for the exact rules.

**Since onboarding:** `ollama-chat`'s own production traffic was rerouted through this gateway
(`ollama-chat` ADR-0014, 2026-07-30) so its call volume shows up in the gateway's metrics too,
and the gateway gained a bundled MongoDB for per-call history (`homelab-gateway` ADR-0001,
2026-07-30) — its **first** stateful, PVC-backed workload. Neither change touched anything in
this repo beyond what's already reflected in `docs/architecture.md`.

## Alternatives Considered

- **Give `homelab-gateway` its own MetalLB IP, like Whisper/Piper got** — rejected: by the
  time this was onboarded the pool had only 4 free addresses left; routing through
  `ingress-nginx` by hostname, same as `ollama-chat`, costs zero additional IPs.
- **Build the routing/metrics logic into `ollama-chat`'s own Express backend instead of a
  separate service** — rejected: this needed to front Whisper/Piper/Ollama generically, not
  just for `ollama-chat`'s own calls, and keeping it a standalone service means any future
  client (not just this one chat UI) gets the same unified entry point and metrics for free.

## Consequences

**Good:**
- One entry point, one place to look at request volume/latency/model usage across all three
  backends, instead of three separate IPs with no shared visibility.
- Reuses the same git-source Application recipe ADR-0015 established — no new onboarding
  pattern needed.

**Neutral:**
- A fourth external repo (`homelab-gateway`) now matters for "is the LLM stack deployed
  correctly," alongside `ollama-chat`, `piper-tts-server`, and this repo.

**Negative:**
- `ollama-chat` (since its own ADR-0014) now has a runtime dependency on `homelab-gateway`
  being healthy in addition to Ollama/Whisper/Piper themselves — if the gateway pod is down,
  chat and vocal mode both fail even though the backends are fine.
