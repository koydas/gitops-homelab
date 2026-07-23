# ADR-0006: GitOps Repo Kept Public

**Date:** 2026-07-23  
**Status:** Accepted

---

## Context

The repo was created as private by default in planning, but the actual `gh repo create --private` call failed silently against an already-existing repo of the same name, and the pre-existing repo turned out to be public. The operator was asked explicitly whether to flip it to private now that this was noticed.

---

## Decision

**Keep the repo public.** No secrets are stored in it — no ArgoCD credentials, no API tokens, no model weights. The MetalLB IP range and internal LAN topology it reveals are only useful to someone already on the home network.

---

## Considered Alternatives

### Make it private
This was the recommended option when the question was raised (consistent with the original plan's assumption of a private repo) but explicitly declined by the operator, who was comfortable with the current contents being public.

---

## Consequences

**Good:**
- No access-control setup needed for anyone who might help maintain it.
- Nothing operationally changes if the repo is later made private — GitOps flow is identical either way.

**Neutral:**
- The `install-host.sh` preflight logic, MetalLB range, and architectural choices are visible to anyone. None of this is considered sensitive for a home-network setup.

**Negative:**
- Any future secret accidentally committed (an API key in an `Application` manifest, for instance) would be immediately publicly exposed. Nothing currently in the repo does this, but this is the standing risk of the public choice — worth a second look before adding any app that needs a credential.
