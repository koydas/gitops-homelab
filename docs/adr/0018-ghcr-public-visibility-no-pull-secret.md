# ADR-0018: GHCR images pulled via public package visibility, no `imagePullSecret` in Git

**Date:** 2026-07-30
**Status:** Accepted

---

## Context

Three git-source Applications now pull custom-built images from `ghcr.io/koydas/*`:
`ollama-chat`, `piper` (`koydas/piper-tts-server`), and `homelab-gateway` — each published by
that repo's own `docker-publish.yml` on push to `main` (see
[ADR-0015](./0015-ollama-chat-git-source-application.md) and
[ADR-0016](./0016-onboard-whisper-piper-cpu-only.md)). None of the three Deployments, and
nothing in this repo's `apps/`, sets an `imagePullSecret`. A pull only works because each
GHCR package is manually flipped to **Public** visibility — a fresh GHCR package defaults to
**private** regardless of the source repo's own visibility (confirmed in `ollama-chat`'s own
[ADR-0006](https://github.com/koydas/ollama-chat/blob/main/docs/adr/0006-gitops-deployment-via-ghcr.md),
which flagged this as a consequence when that repo was onboarded). That decision was recorded
once, in one of the three repos, and never carried over here or to `homelab-gateway` — this
repo is what actually owns the Applications that depend on it holding true, so it needs its
own record and its own README callout (added alongside this ADR, see "GHCR package visibility"
and "Manual post-install steps" in `README.md`).

As of this writing, verified by an anonymous `ghcr.io/v2/<pkg>/tags/list` pull (200 = public,
no token needed beyond GHCR's own anonymous bearer exchange):

```
koydas/ollama-chat:      200
koydas/homelab-gateway:  200
koydas/piper-tts-server: 200
```

All three are public today. Nothing in this repo's CI (`validate.yml`) checks this — it's a
GitHub-side setting outside the manifests it validates.

---

## Decision

**Keep relying on public GHCR package visibility instead of a Git-managed `imagePullSecret`.**
No pull secret, sealed or otherwise, is added to this repo. Visibility is checked manually
(command in the README) as part of the documented manual post-install steps, not automated.

---

## Considered Alternatives

### Commit a `docker-registry` Secret (PAT-based) for each Application's namespace
Rejected: would mean storing a GitHub PAT with `read:packages` scope somewhere reachable by
this repo's sync flow. This repo is deliberately kept public
([ADR-0006](./0006-public-repo-visibility.md)) with "no secrets, no API tokens" as the stated
reason it's safe to be public — adding a packages-read token, even scoped narrowly, breaks
that invariant for a single-user homelab where the alternative (flip a visibility toggle
once) costs nothing.

### Seal the pull-secret token with a tool like Bitnami Sealed Secrets or SOPS
Rejected: introduces a new component (a sealing controller or a KMS/GPG key management step)
to avoid a one-click GitHub Package setting, for a homelab where every image involved is
already meant to be public (this repo's own code, `ollama-chat`, `piper-tts-server`,
`homelab-gateway` — none are proprietary). Worth revisiting only if a future app's image
genuinely needs to stay private.

### Create the pull secret imperatively out-of-band (like `grafana-admin-credentials`)
Rejected as the *primary* mechanism, though it remains the fallback if a package is ever found
private: this repo already has one class of "manual Secret creation" documented for
`monitoring` ([ADR-0012](./0012-monitoring-stack.md)); adding a second, permanent one for
something a free visibility toggle solves adds an ongoing operational step (created once, but
now something that must survive/be reproduced on every rebuild) for no corresponding benefit
over just keeping the packages public.

---

## Consequences

**Good:**
- Zero credentials to create, rotate, or reproduce across a cluster rebuild — one less item on
  the "what does *not* come back automatically" list in `README.md`.
- Consistent with this repo's existing public-by-default posture (ADR-0006).

**Neutral:**
- The decision now lives in this repo (which owns the Applications), not only in
  `ollama-chat`'s repo (which owned it first, for itself) — `homelab-gateway`'s repo still has
  no equivalent note; this repo's README callout is now the source of truth for all three.

**Negative:**
- Silent failure mode: if any of the three packages is ever flipped private — by GitHub policy
  change, an org default, or manual error — the affected pod fails with `ImagePullBackOff` with
  no warning from CI (`validate.yml` cannot see GitHub Package visibility) and no self-heal
  ArgoCD can perform. Detection is manual (README's `tags/list` check, or noticing the pod
  state after a sync). Re-check visibility after recreating any of the three GHCR packages
  (e.g. deleting/recreating the source repo resets it to private).
