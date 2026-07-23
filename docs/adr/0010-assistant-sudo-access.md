# ADR-0010: Full Passwordless Sudo Granted to the Assistant Session

**Date:** 2026-07-23  
**Status:** Accepted

---

## Context

The AI assistant building this stack (Claude Code) had no way to authenticate an interactive `sudo` prompt from its tool environment — no TTY is attached, so `sudo` fails with `A terminal is required to authenticate` even when the operator manually ran the command via the session's shell passthrough. Without privileged access, every install step (`snap install microk8s`, `usermod`, later `kubectl` operations run as root) would have required the operator to manually run each command themselves in a separate terminal and relay the output back — workable, but slow and error-prone for a multi-hour, many-step build.

The operator was asked explicitly to choose between a narrowly-scoped `NOPASSWD` rule (limited to the specific commands this setup needs: `snap`, `microk8s`, `usermod`, `apt`) or full `NOPASSWD:ALL`.

---

## Decision

Full **`NOPASSWD:ALL`** was granted, via `/etc/sudoers.d/99-claude-nopasswd`, applied by the operator directly (the assistant cannot write to `/etc/sudoers.d` without sudo access in the first place — this had to be a manual, operator-executed step). Every privileged command in this build (microk8s install, ArgoCD install, GPU addon, all `kubectl`/`microk8s kubectl` operations, `apt`, log inspection via `journalctl`/`ctr`) was run this way for the remainder of the session.

---

## Considered Alternatives

### Scoped `NOPASSWD` for a specific command allowlist
Offered as the recommended, lower-risk option — would have covered the commands anticipated at the time (`snap`, `microk8s`, `usermod`, `apt`) but not, as it turned out, later needs like `journalctl` and `ctr` for debugging the `ContainerCreating` incident in [runbook.md](../runbook.md). Declined by the operator in favor of full access.

---

## Consequences

**Good:**
- The entire build — including live debugging of the kubelet-lag incident, which needed ad hoc access to `journalctl`, `ctr`, and `crictl`-equivalent inspection that wouldn't have been on any pre-approved allowlist — proceeded without interrupting the operator for each individual privileged command.

**Neutral:**
- This grant is host-wide and persistent (a file in `/etc/sudoers.d/`, not scoped to a session or time window) — it remains in effect after this build session ends, until explicitly revoked.

**Negative:**
- Equivalent to permanent root access on this box for whatever runs in this assistant session going forward, not just for this build. The operator was told explicitly how to revoke it (`sudo rm /etc/sudoers.d/99-claude-nopasswd`) — see [runbook.md](../runbook.md) for the open reminder to reconsider this.
