# Request flows

How a request actually gets to a pod, for the three paths this cluster serves.

## Ollama inference

1. Client (curl, Postman, or the `ollama` CLI pointed at `OLLAMA_HOST`) sends an HTTP request to `192.168.1.241:11434`.
2. MetalLB (L2 mode) routes it to the `ollama` Service, which forwards to the `ollama` Deployment's single pod.
3. The pod has `nvidia.com/gpu: 1` requested and `runtimeClassName: nvidia`, so inference runs on the GTX 1060 rather than falling back to CPU (see [ADR-0003](./adr/0003-ollama-in-cluster.md)).
4. Model weights are read from the PVC (`/root/.ollama`), which persists across pod restarts.

## Via homelab-gateway

`ollama-chat`'s production backend (chat, STT, and TTS calls alike) no longer talks to
Ollama/Whisper/Piper directly — it's proxied through `homelab-gateway`, the unified LAN entry
point onboarded in [ADR-0020](./adr/0020-onboard-homelab-gateway.md) and rerouted into by
`ollama-chat`'s own [ADR-0014](https://github.com/koydas/ollama-chat/blob/main/docs/adr/0014-route-production-traffic-through-homelab-gateway.md).

1. `ollama-chat`'s Express backend sends its `OLLAMA_URL`/`WHISPER_URL`/`PIPER_URL` calls to
   `homelab-gateway.homelab-gateway.svc.cluster.local:80` instead of each backend's own
   Service.
2. `homelab-gateway` picks the right backend by sniffing `Content-Type` and JSON body shape
   (audio/multipart → Whisper `/asr`, JSON `text` field → Piper `/tts`, JSON `model` field or
   bodiless → Ollama, path preserved) — see that repo's `docs/routing.md` for the full rule set.
3. Every proxied call is recorded as a Prometheus metric (`gateway_http_requests_total`,
   `gateway_ollama_model_requests_total{model}`, scraped by the `monitoring` Application) and
   as a MongoDB document with the full request/response (`homelab-gateway`
   [ADR-0001](https://github.com/koydas/homelab-gateway/blob/main/docs/adr/0001-mongodb-call-log.md),
   stored on the `homelab-gateway-mongo` PVC).
4. `homelab-gateway` itself is reached via `ingress-nginx` at `gateway.home`
   (`192.168.1.243`), the same pattern as `ollama-chat.home`.

## Voice mode: STT/TTS

1. The browser records a message (or gets a reply to speak) and calls `ollama-chat`'s
   Express backend at `/api/stt` or `/api/tts` (same MetalLB IP/Ingress as the chat UI
   itself, `192.168.1.244` / `ollama-chat.home`).
2. Express proxies the request to `homelab-gateway` (see above), which routes it in-cluster
   via Service DNS: `/asr` → `whisper.whisper.svc.cluster.local:9000`
   (`onerahmet/openai-whisper-asr-webservice`), `/tts` →
   `piper.piper.svc.cluster.local:8000` (the custom `piper-tts-server`) — no Express-side
   body parsing on either hop, both are pure byte-stream proxies, mirroring how it already
   talks to Ollama.
3. Both Whisper and Piper run CPU-only (see [ADR-0016](./adr/0016-onboard-whisper-piper-cpu-only.md))
   — the GTX 1060 stays dedicated to Ollama.
4. Each also has its own LoadBalancer IP (`192.168.1.245` Whisper, `192.168.1.246` Piper) so
   `ollama-chat`'s local Vite dev server can reach them directly, without going through
   `homelab-gateway` or the Express backend at all — same as local dev already reaches Ollama
   directly at `192.168.1.241`, bypassing the gateway too.
