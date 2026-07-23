# ADR-0002: LAN-Only Exposure via MetalLB, No Public Ingress

**Date:** 2026-07-23  
**Status:** Accepted

---

## Context

ArgoCD and Ollama both need to be reachable from a browser/client without SSH tunneling or `kubectl port-forward` on every use. The operator was asked directly whether these services should be reachable only on the home LAN, or exposed externally with a domain and TLS.

---

## Decision

**LAN-only.** MetalLB (L2 mode) hands out stable IPs from a reserved range (`192.168.1.240-192.168.1.250`) on the home network; both ArgoCD (`192.168.1.240`) and Ollama (`192.168.1.241`) are `Service: LoadBalancer` reachable directly from any device on the LAN. No ingress controller, no public domain, no cert-manager/TLS.

---

## Considered Alternatives

### Public ingress + domain + TLS (cert-manager, Let's Encrypt)
Explicitly offered as the alternative during initial requirements gathering. Rejected — no current need for access outside the home network, and it adds a meaningful amount of infrastructure (ingress controller, DNS, certificate issuance/renewal, exposure to the public internet) for no immediate benefit.

### `kubectl port-forward` per session
Not explicitly discussed, but implicitly rejected by choosing MetalLB — port-forwarding requires an active shell session and re-running the command every time, which does not scale to "browse to ArgoCD whenever."

---

## Consequences

**Good:**
- Simple, no certificates to manage, no attack surface exposed to the public internet.
- Stable IPs (not `ClusterIP` + port-forward) make both services trivially reachable from any LAN device, including this Postman collection.

**Neutral:**
- The chosen range (`192.168.1.240-192.168.1.250`) was picked heuristically (most home routers default their DHCP pool below `.200`) rather than confirmed against the actual router configuration — see the open item in [runbook.md](../runbook.md).

**Negative:**
- No GitHub webhook is possible (GitHub cannot reach a LAN-only IP), so ArgoCD relies on its default ~3 minute polling interval instead of instant sync on push. A hard refresh can be forced manually when faster feedback is needed.
- If external access is ever wanted later, this decision needs revisiting (ingress + TLS + possibly a reverse tunnel or dynamic DNS, since there's no public IP on this connection by default).
