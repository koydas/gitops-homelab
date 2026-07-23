---
name: adr-new
description: Scaffold a new Architecture Decision Record in this repo's docs/adr/, following the existing numbering and section format, and update the index. Use when a real decision was made (a technology/config choice, a tradeoff, something worth explaining to a future reader) that should be documented the way this repo documents decisions — not for routine changes.
---

# New ADR for gitops-homelab

This repo documents real decisions as numbered ADRs in `docs/adr/`, indexed in `docs/adr/README.md`. Format follows `koydas/autonomous-dev-loop`. There are 11 so far (as of 2026-07-23) — always check the current count rather than assuming a number.

## When this is actually warranted

An ADR records a decision with real alternatives and consequences — a technology pick, a security/exposure tradeoff, a version pin with a reason, a benchmark-driven config choice (see [ADR-0011](../docs/adr/0011-ollama-q4-quantization.md) for a data-driven example). It is not for routine model bumps, typo fixes, or anything without a genuine "why this and not that."

## Steps

1. **Find the next number:**
   ```bash
   ls docs/adr/ | grep -E '^[0-9]{4}-' | sort | tail -1
   ```
   Increment by one, zero-padded to 4 digits.

2. **Write `docs/adr/00NN-<short-kebab-slug>.md`** using this exact section structure (copy the shape, not the content, from an existing ADR like [0004](../docs/adr/0004-ollama-helm-deployment.md) or [0011](../docs/adr/0011-ollama-q4-quantization.md)):

   ```markdown
   # ADR-00NN: <Decision, stated as a title, not a question>

   **Date:** YYYY-MM-DD
   **Status:** Accepted

   ---

   ## Context

   <What situation forced this decision. Link related ADRs with relative markdown links.>

   ---

   ## Decision

   <The decision, stated plainly, one or two sentences.>

   ---

   ## Considered Alternatives

   ### <Alternative 1>
   <Why it was or wasn't chosen — concrete reasons, ideally with evidence (benchmarks, verified facts), not hand-waving.>

   ---

   ## Consequences

   **Good:**
   - ...

   **Neutral:**
   - ...

   **Negative:**
   - ...
   ```

   Ground every claim in something actually verified in this session (a command run, a benchmark, a doc read) — this repo's existing ADRs cite specific evidence (e.g. ADR-0004 mentions pulling the chart's `values.yaml` to confirm field names rather than guessing).

3. **Add it to the index** in `docs/adr/README.md`, same one-line format as the existing entries.

4. **Commit** (ask before pushing, per this session's general git-safety norms — pushing to this public repo is a visible action):
   ```bash
   git add docs/adr/00NN-*.md docs/adr/README.md
   git commit -m "Add ADR-00NN: <short summary>"
   ```
