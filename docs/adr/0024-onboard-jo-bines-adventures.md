# ADR-0024: Onboard `jo-bines-adventures` as a git-source Application

**Date:** 2026-08-14
**Status:** Accepted

---

## Context

`koydas/jo-bines-adventures` is a monorepo holding two things: `_legacy/`
(the original GameMaker Studio 2 project) and `web/` (a static
TypeScript/Phaser 3 port, no backend, no persistence). Only `web/` is
deployable — a Dockerfile there builds it into an Nginx image, and it now
carries its own `web/k8s/` (Deployment, Service, Ingress), added in the same
session as this ADR. This is the same shape `healing-simulator` already
onboarded in ([ADR-0023](./0023-onboard-healing-simulator.md)): a custom app
with no Helm chart, built and published from its own repo.

Two things differ from that precedent and are worth recording:

- The repo's default branch is **`master`**, not `main`.
- `master` carries **no branch protection** (verified via
  `gh api repos/koydas/jo-bines-adventures/branches/master/protection` →
  404 "Branch not protected", and
  `.../actions/permissions/workflow` already reports
  `default_workflow_permissions: write`). healing-simulator's
  `docker-publish.yml` opens and auto-merges a PR to bump its deployed tag
  specifically to work around branch protection (ADR-0012/ADR-0014 in that
  repo); with nothing to work around here, `jo-bines-adventures`'s
  `docker-publish.yml` pushes the tag-bump commit straight to `master`
  instead — simpler, and there is no protected-branch/Actions-permission
  trap to hit later. If branch protection is ever turned on for this repo,
  that workflow needs the same PR-based fix healing-simulator already has.

## Decision

`apps/jo-bines-adventures/application.yaml` uses a **git source**, same
recipe as ADR-0023:

```yaml
source:
  repoURL: https://github.com/koydas/jo-bines-adventures.git
  targetRevision: master
  path: web/k8s
```

Same `project: homelab`, `syncPolicy.automated: { prune: true, selfHeal: true }`
and `CreateNamespace=true` as every other Application here. `apps/appproject.yaml`
gets `https://github.com/koydas/jo-bines-adventures.git` added to `sourceRepos`
and `jo-bines-adventures` added to `destinations`. No `clusterResourceWhitelist`
change needed: Deployment, Service and Ingress are all namespace-scoped.

`jo-bines-adventures`'s own repo carries a `docker-publish.yml` workflow
(`web/` as build context and working directory) that builds the image,
pushes it to `ghcr.io/koydas/jo-bines-adventures`, and — after the fast
Playwright smoke suite passes — commits the built tag back into
`web/k8s/deployment.yaml`; that commit is what this Application syncs on.
Per [ADR-0018](./0018-ghcr-public-visibility-no-pull-secret.md), the GHCR
package needs to be set to public visibility by hand after the first push
(no `imagePullSecret` is carried in the Deployment), same one-time follow-up
as every other app here.

Unlike ADR-0023's `healing-simulator` (ingress-only), this app's Service
carries its own pinned MetalLB address (`192.168.1.248`) in addition to
being routed through `ingress-nginx` at `jo-bines-adventures.home` — that
actually matches what `healing-simulator`'s and `ollama-chat`'s Services
*do* today (both also carry a pinned MetalLB IP alongside their Ingress),
even though ADR-0023's prose says otherwise; the Service manifest is the
ground truth here, not that sentence. Every app in this fleet that is meant
to be opened directly by a human ends up with both: the IP works with zero
client-side config, the hostname is the nicer one to remember.

## Alternatives Considered

- **Copy the manifests into this repo under `apps/jo-bines-adventures/`** —
  rejected, same reasoning as ADR-0015/ADR-0023: splits one app's deployment
  definition across two repos.
- **Keep the deploy-PR dance from healing-simulator** — rejected: it exists
  specifically to route around branch protection, and this repo's `master`
  has none. Adding the extra PR/merge steps here would just be more surface
  area for the exact `GraphQL: GitHub Actions is not permitted to create or
  approve pull requests` failure healing-simulator already hit once, for no
  benefit.
- **Ingress-only, no dedicated IP** (what ADR-0023's prose describes for
  healing-simulator) — rejected once the actual `healing-simulator/k8s/service.yaml`
  and `ollama-chat` were checked: both already carry a pinned MetalLB IP
  today. Onboarding this app the same way it's actually done elsewhere beats
  onboarding it the way an older ADR's text says it was done.

## Consequences

**Good:**
- Third confirmation (after `ollama-chat`, `healing-simulator`) that the
  git-source Application pattern generalizes cleanly to homegrown, non-Helm
  apps.
- No PR-dance complexity in `docker-publish.yml` — a genuinely simpler
  workflow than healing-simulator's, because there's nothing here to work
  around.

**Neutral:**
- Two repos matter for "is `jo-bines-adventures` deployed correctly": this
  one for the Application/AppProject wiring, `jo-bines-adventures` itself
  for the manifests and image pipeline.
- Uses IP `192.168.1.248`, the next free address in the MetalLB pool after
  `.240`–`.247` (ingress-nginx, ollama-chat, whisper, piper, healing-simulator
  all already pinned).

**Negative:**
- If `master` ever gains branch protection, `docker-publish.yml`'s direct
  push starts failing silently-ish (images build, tag-bump push rejected,
  deployment goes stale) exactly like healing-simulator's PR-based version
  did for the opposite reason — same class of failure, worth a `gh run list
  --workflow docker-publish` check after any future repo-settings change on
  either repo.
