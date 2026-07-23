# ADR-0011: Ollama Models Pinned to Q4_0 Quantization, Not Q5_K_M

**Date:** 2026-07-23  
**Status:** Accepted

---

## Context

The GPU is a GTX 1060 6GB (Pascal, no tensor cores, ~192GB/s memory bandwidth). `apps/ollama/application.yaml`'s `models.pull` lists three Q4_0 tags (`llama3.1:8b-instruct-q4_0`, `qwen2.5:0.5b`, `qwen2.5-coder:7b-instruct-q4_0`), leaving roughly 1.2-1.7GB of VRAM free after the largest of them is loaded. That headroom raised the question of whether switching to a higher-precision quant (Q5) would give meaningfully better output for tasks that need it.

`qwen2.5-coder:7b-instruct-q5_K_M` was pulled ad hoc via `ollama pull` directly in the pod (the manual workflow documented in the runbook, not a `models.pull` change) to benchmark against the two Q4_0 models already in Git.

---

## Decision

Keep `models.pull` at Q4_0 only. Do not add Q5_K_M (or higher) quants for 7-8B models on this GPU.

---

## Considered Alternatives

### `qwen2.5-coder:7b-instruct-q5_K_M`

Benchmarked directly: the same complex prompt (a Python red-black tree with insert/delete/search plus unit tests) was sent to `qwen2.5-coder` Q4_0, `llama3.1:8b` Q4_0, and `qwen2.5-coder` Q5_K_M, with `nvidia-smi` sampled at 1Hz throughout each run.

| Model | tok/s | Peak VRAM | GPU utilization pattern |
|---|---|---|---|
| qwen2.5-coder 7B Q4_0 | 26.6 | 4379 MiB | 93-96%, steady — compute-bound |
| llama3.1 8B Q4_0 | 25.5 | 4869 MiB | 93-97%, steady — compute-bound |
| qwen2.5-coder 7B Q5_K_M | 16.5 (-38%) | 4951 MiB | 70-79%, spiky power draw — memory-bandwidth-bound |

At Q5 the GPU spends part of its time waiting on memory reads for the larger weights rather than computing — utilization *drops* even though the request takes longer, the signature of shifting from a compute-bound to a bandwidth-bound workload on this card.

Quality was checked by actually executing each response's generated code and its own unit tests, not just reading it. All three configurations failed their own tests, but Q5 did not trade latency for a better result: it reproduced the exact same bug as the Q4 qwen run (`insert_fixup`/`fix_insert` dereferences `node.parent.color` without a root-node guard) and additionally omitted the `delete` method from its output entirely, despite a longer response time (77s vs 49s).

### 13B-class models (even in a tight quant)

Not evaluated — a 13B model at Q4 (~7.5-8GB) does not fit in 6GB VRAM alongside the existing setup and would require partial CPU offload. Would need its own benchmark if ever considered.

---

## Consequences

**Good:**
- Compute stays the bottleneck at Q4 (93-97% GPU utilization) instead of shifting to memory bandwidth, which is this Pascal card's weaker resource.
- VRAM headroom (~1.2-1.7GB free at Q4) stays available for context growth or a second small model instead of being consumed by a quant upgrade that measured worse on quality-per-token/sec.

**Neutral:**
- Not re-evaluated if the GPU changes (see [server hardware notes] — a card with materially more memory bandwidth or VRAM would invalidate this comparison).

**Negative:**
- Locks in known-imperfect output quality: all three tested configurations (two quants, two models) failed their own generated unit tests on red-black tree deletion. Precision isn't the limiting factor for this class of algorithmic task at the 7-8B scale, so this decision doesn't chase a fix that doesn't exist at this model size — a real quality gain here would require a different/larger model, not a different quant.
