---
name: gitops-model-bump
description: Add or change an Ollama model tag the GitOps way in this repo — validates the tag exists, edits application.yaml, commits, pushes, and force-syncs ArgoCD. Use when asked to permanently add/bump/remove an Ollama model (not for ad-hoc testing — that's a plain `ollama pull` in the pod, see the ollama-bench skill).
---

# Add/bump an Ollama model via GitOps

The model list lives in Git, not just in the running pod. A model pulled directly in the pod (`ollama pull`) works for testing but is invisible to Git and will not survive a pod recreation unless it's also in `models.pull` here. This is the permanent-change path — see `docs/runbook.md` § "Bump or add an Ollama model" for the canonical version of this flow.

## Steps

1. **Validate the tag actually exists** before touching Git — a typo is a silent-until-sync failure, not a CI failure (CI only validates YAML shape, see [ADR-0009](../docs/adr/0009-static-ci-validation.md)):
   ```bash
   curl -s -o /dev/null -w "%{http_code}\n" https://registry.ollama.ai/v2/library/<model>/manifests/<tag>
   ```
   200 = exists, 404 = check spelling/tag.

2. **Edit `apps/ollama/application.yaml`**, under `spec.source.helm.valuesObject.ollama.models.pull` — add/change/remove the tag in that list. Preserve alphabetical-ish ordering if the existing list has a pattern; otherwise append.

3. **Removing a tag from the list does NOT delete it from the PVC** — the chart's `models.clean` is deliberately left `false` (see [ADR-0004](../docs/adr/0004-ollama-helm-deployment.md)). If you're replacing a model, prune the old one manually after the new one is confirmed working:
   ```bash
   sudo microk8s kubectl -n ollama exec deploy/ollama -- ollama rm <old-tag>
   ```

4. **Commit and push:**
   ```bash
   git add apps/ollama/application.yaml
   git commit -m "Add/bump model: <tag>"
   git push
   ```

5. **Force an immediate sync** instead of waiting for ArgoCD's ~3 min poll:
   ```bash
   sudo microk8s kubectl -n argocd annotate application ollama argocd.argoproj.io/refresh=hard --overwrite
   ```

6. **Verify:**
   ```bash
   sudo microk8s kubectl -n argocd get application ollama -o custom-columns=SYNC:.status.sync.status,HEALTH:.status.health.status
   sudo microk8s kubectl -n ollama exec deploy/ollama -- ollama list
   ```

If this model choice reflects a real decision (not just routine housekeeping) — e.g. picking a quant/size after comparing options — use the `adr-new` skill to record why, following the pattern of [ADR-0011](../docs/adr/0011-ollama-q4-quantization.md).
