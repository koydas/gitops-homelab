# ADR-0007: Dedicated `homelab` AppProject for Workload Apps

**Date:** 2026-07-23  
**Status:** Accepted

---

## Context

Initially, `apps/ollama/application.yaml` used ArgoCD's built-in `default` project, which has no source/destination restrictions. This was fine with a single app, but was revisited as one of a set of repo-hardening additions once the base stack was confirmed working, anticipating more workload apps being added later (the Postman collection's health-check tests already reference a hypothetical future service, and the operator specifically named "a chat UI in front of Ollama" as a plausible next addition in conversation).

---

## Decision

Add a dedicated **`homelab`** `AppProject` (`apps/appproject.yaml`) scoping allowed source repos (this GitHub repo + the Ollama Helm repo) and allowed destination namespaces (currently just `ollama`). `apps/ollama/application.yaml` was switched from `project: default` to `project: homelab`. The bootstrap `root` Application itself stays on `default`, since it's the special entrypoint applied imperatively once, not a workload.

The `AppProject` carries `argocd.argoproj.io/sync-wave: "-1"` so ArgoCD creates it before the Applications that reference it, avoiding a race where `ollama` tries to sync against a project that doesn't exist yet.

---

## Considered Alternatives

### Leave everything on `default`
Simplest, and was the original state. Rejected as a deliberate hardening step once more than one workload app became plausible — `default` has no restrictions, so a future app added carelessly (or a typo'd `repoURL`) could pull from or deploy to anywhere with no guardrail.

---

## Consequences

**Good:**
- Future workload apps must be added to `homelab`'s `destinations` list explicitly — a small, visible Git diff — rather than silently gaining access to arbitrary namespaces.
- `sourceRepos` scoping means only this repo and the Ollama Helm repo can be referenced by `homelab`-scoped apps, catching a copy-pasted wrong `repoURL` at sync time instead of it silently succeeding.

**Neutral:**
- For a single app, this project provides no observable behavior difference today — its value is entirely in guarding against future additions.

**Negative:**
- One more file to keep in sync: adding a new workload app now requires both the `Application` manifest *and* a `destinations` entry in `apps/appproject.yaml`, or the sync will fail with a project-permission error.
