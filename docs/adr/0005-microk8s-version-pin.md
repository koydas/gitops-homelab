# ADR-0005: Pin microk8s to `1.35/stable`, Overriding an Initial `1.32` Recommendation

**Date:** 2026-07-23  
**Status:** Accepted

---

## Context

Initial planning research surfaced a real, closed GitHub issue (canonical/microk8s#5229) describing microk8s 1.33/1.34 GPU addon pods hanging in `Init` state — on a driver/CUDA combination (580/CUDA 13) matching this host almost exactly. The first plan draft, based on that finding alone, recommended pinning microk8s to the older `1.32/stable` channel to sidestep the bug entirely.

Before executing that plan, the recommendation was checked more closely rather than taken at face value: the actual closed-issue resolution thread (fetched via the GitHub API, not just the issue title/summary) showed the root cause was **not** an inherent 1.33/1.34 incompatibility. It was a separately apt-installed `containerd.io` package conflicting with microk8s's bundled containerd (`containerd config version 3 is not supported, the max version is 2`), fixed by removing the apt package. This host was checked directly (`dpkg -l | grep containerd`) and has no containerd/Docker installed at all — the failure mode the 1.32 pin was meant to avoid does not apply here.

---

## Decision

Use the latest available stable channel at setup time, **`1.35/stable`**, instead of downgrading to `1.32/stable`. `bootstrap/install-host.sh` includes a preflight check that refuses to proceed if a conflicting apt `containerd` package is ever present, directly addressing the actual root cause instead of avoiding a version that was never really the problem.

---

## Considered Alternatives

### Pin to `1.32/stable` (the original recommendation)
Rejected after root-cause verification (see Context) — downgrading to avoid a bug that doesn't apply to this host would mean permanently missing fixes and improvements in 1.33-1.35 for no actual benefit.

---

## Consequences

**Good:**
- Runs the most current stable microk8s release rather than an artificially held-back one.
- The preflight check in `install-host.sh` guards against the *actual* failure mode (apt containerd conflict) rather than a superficial one (version number), so it remains useful even if microk8s minor versions change in the future.

**Neutral:**
- If this host ever gains an apt-installed `containerd`/`docker.io` package for an unrelated reason, the same class of failure could resurface — the preflight check will catch it before the GPU addon is touched, per `bootstrap/install-host.sh`.

**Negative:**
- This decision rests on interpretation of one closed GitHub issue's resolution thread; if the root cause analysis in that thread was itself incomplete, the risk this ADR dismisses could still apply. Not independently re-verified beyond reading the maintainers' own resolution.
