# ADR-0009: CI Validates Manifests Statically, Does Not Deploy to a Test Cluster

**Date:** 2026-07-23  
**Status:** Accepted

---

## Context

Added as one of a set of repo-hardening steps once the base stack was confirmed working: catch a broken manifest (bad YAML, a typo'd field name, a schema-invalid resource) before ArgoCD tries to sync it against the real cluster, rather than discovering the break live.

---

## Decision

`.github/workflows/validate.yml` runs `yamllint` (syntax) and `kubeconform` (schema validation against the `datreeio/CRDs-catalog`, covering ArgoCD's `Application`/`AppProject` CRDs and MetalLB's `IPAddressPool`/`L2Advertisement` CRDs) on every push and PR. Both run on GitHub-hosted runners and require no access to the actual cluster.

---

## Considered Alternatives

### Spin up an ephemeral cluster (kind/k3d) in CI and actually apply the manifests
Would catch a strictly larger class of errors (e.g. the `Application` referencing a `project` that doesn't exist, or a Helm `valuesObject` field that's schema-valid YAML but semantically wrong for the chart version). Not pursued — GitHub-hosted runners have no route to this LAN-only cluster (see [ADR-0002](./0002-lan-only-exposure.md)), so even a successful ephemeral-cluster test wouldn't validate against the real GPU/MetalLB/storage environment this actually needs to run on; the gap between "passes in a generic kind cluster" and "works on this specific box" would remain, for a meaningful increase in CI complexity and runtime.

---

## Consequences

**Good:**
- Catches the most common failure class (syntax errors, malformed CRs) before they ever reach ArgoCD — verified live: the workflow correctly went green on the commit that introduced it, and on every subsequent commit.
- Fast (single-digit seconds) and has no dependency on cluster availability, so it runs the same whether or not the home server is reachable.

**Negative:**
- Does not catch semantic errors within a schema-valid manifest (e.g. a valid but nonexistent Helm chart value, or a `models.pull` tag that doesn't exist on the Ollama registry — exactly the class of typo caught manually, not by CI, when `qwen2.5-coder:7b-instuct-q4_0` was checked against the registry before being committed). A live sync against the real cluster remains the actual test of correctness for anything CI can't see.
